//
//  PremiumService.swift
//  IntegrationKit
//
//  Single source of truth for premium access. Adapty decides, Apple's receipt is the
//  reserve, the cache covers the offline launch. Nothing else writes the premium flag.
//

import Adapty
import Foundation

final class PremiumService: PremiumServicing {
	private let store: PremiumStateStoring
	private let adapty: AdaptyPremiumProviding?
	private let apple: AppleSubscribing?
	/// Access level ids as named in the Adapty dashboard — the app decides, not the library.
	private let levels: Set<String>
	// Guards the cached state AND its flag mirror together — see `apply`.
	// Holding it across the mirror write is safe: the store's setter posts `.premiumDidChange`
	// on `DispatchQueue.main.async`, so no observer ever runs inside this critical section.
	// Recursive anyway, so that a future synchronous notification cannot turn into a self-deadlock.
	private let lock = NSRecursiveLock()
	/// How long `refresh()` waits for one source before deciding without it. Five seconds is a
	/// number from practice, not a guarantee Adapty documents — an app on a worse network passes
	/// its own instead of patching the package.
	private let sourceTimeout: TimeInterval

	init(
		store: PremiumStateStoring = UserDefaultsPremiumStore(),
		adapty: AdaptyPremiumProviding? = nil,
		apple: AppleSubscribing? = nil,
		levels: Set<String> = ["premium"],
		sourceTimeout: TimeInterval = 5
	) {
		self.store = store
		self.adapty = adapty
		self.apple = apple
		self.levels = levels
		self.sourceTimeout = sourceTimeout
	}

	/// Convenience read for call sites that just need the current answer.
	var isPremium: Bool {
		store.cached?.isPremium ?? false
	}

	/// PM-01: seeds the cache on the first launch after the update, then publishes what we know.
	func start() {
		lock.lock()
		if store.cached == nil {
			let wasPremium = store.premium
			store.cached = PremiumState(
				isPremium: wasPremium,
				source: wasPremium ? .legacy : .none,
				isVerified: false
			)
		}
		lock.unlock()
		apply(adapty: nil, apple: nil)

		adapty?.premiumObserver = { [weak self] profile in
			guard let self else { return }
			self.apply(adapty: PremiumAccess(profile: profile, levels: self.levels))
		}
		refresh()
	}

	/// PM-02: one barrier instead of two in-flight flags. Both sources are asked at once and the
	/// verdict is taken when both have answered — one resolve, one store write, one notification.
	/// A source that never answers costs `sourceTimeout` and nothing more: there is no flag left
	/// raised, so it cannot block any later `refresh()`.
	///
	/// An intermediate state no longer exists either: the receipt cannot land first, flash a
	/// value at the UI, and be overwritten by Adapty a moment later.
	func refresh() {
		Task { [weak self] in await self?.resolveBoth() }
	}

	/// The barrier itself, awaitable. `refresh()` fires it and forgets; `restore`/`purchase` await
	/// it, which is what lets their completion run with the verdict already stored.
	///
	/// `localPurchase` marks that a purchase or a StoreKit restore has just gone through on this
	/// device. That is a receipt saying yes, newer than any check we could run — see `apply`.
	private func resolveBoth(localPurchase: Bool = false) async {
		async let adaptyAnswer = askAdapty()
		async let appleAnswer = askApple()
		let (access, receipt) = await (adaptyAnswer, appleAnswer)
		apply(adapty: access, apple: receipt, localPurchase: localPurchase)
	}

	/// `nil` means Adapty did not answer — an error, no source at all, or slower than
	/// `sourceTimeout`. Never "no premium": that is `PremiumAccess(isActive: false)`.
	private func askAdapty() async -> PremiumAccess? {
		guard let adapty else { return nil }
		let profile = await withTimeout(sourceTimeout) { await adapty.profile() }
		return profile.flatMap { $0 }.map { PremiumAccess(profile: $0, levels: levels) }
	}

	/// `nil` means the receipt could not be checked, in time or at all — never "no subscription".
	private func askApple() async -> Bool? {
		guard let apple else { return nil }
		return await withTimeout(sourceTimeout) { await apple.checkReceipt() }.flatMap { $0 }
	}

	/// PM-06: Adapty answered about the premium access level. The delegate push (`didLoadLatestProfile`)
	/// comes in here — a one-way entrance that is deliberately not part of the `refresh()` barrier.
	func apply(adapty: PremiumAccess?) {
		apply(adapty: adapty, apple: nil)
	}

	private func apply(adapty: PremiumAccess?, apple: Bool?, localPurchase: Bool = false) {
		lock.lock()
		// A purchase or a restore that has just gone through is a receipt saying yes, and it is
		// newer than the cache: a verified `inactive` Adapty gave us before the purchase must not
		// swallow it (resolver step 2 would hand that cached state straight back). Only this
		// resolve sees the demoted copy — what gets stored is the verdict below.
		let cached = localPurchase
			? store.cached.map { PremiumState(isPremium: $0.isPremium, source: $0.source, isVerified: false, expiresAt: $0.expiresAt) }
			: store.cached
		let state = PremiumResolver.resolve(adapty: adapty, apple: localPurchase ? true : apple, cached: cached, now: Date())
		// PM-02 rows 2 and 6: one store write per refresh. An answer that resolves to the state already
		// cached writes nothing, so a receipt landing before Adapty cannot flash an intermediate
		// value at the UI and be overwritten a moment later.
		if state != store.cached {
			store.cached = state
		}
		// Both stores move under the same lock: the cached state and the flag mirror must never
		// disagree, which is exactly what happens if the mirror is written after unlock.
		// The mirror is assigned every time — its own setter notifies on change only.
		store.premium = state.isPremium
		lock.unlock()
	}

	// MARK: - PremiumServicing: paywalls and remote config, pass straight through to Adapty.

	func hasPaywall(placement: String) -> Bool {
		adapty?.hasPaywall(placement: placement) ?? false
	}

	func remoteValue<T>(placement: String, key: String) -> T? {
		adapty?.remoteValue(placement: placement, key: key)
	}

	func logPaywallOpen(placement: String) {
		adapty?.logPaywallOpen(placement: placement)
	}

	// MARK: - PremiumServicing: restore and purchase.

	/// StoreKit restore, then the same barrier `refresh()` runs, then the caller hears about it.
	/// Nothing is left for the caller to chase: by the time `completion` fires, `isPremium` is
	/// already the answer. This is the defect the rewrite exists for — `Subtitle Video Translator`
	/// returned success from its own restore and left premium off until the next launch.
	func restore(completion: @escaping (RestoreOutcome) -> Void) {
		guard let apple else {
			DispatchQueue.main.async { completion(.failed) }
			return
		}
		Task { [weak self] in
			// No timeout around this one on purpose: StoreKit may be showing an account prompt,
			// and there is no continuation to leak — the deadline guard belongs to the sources.
			let outcome = await apple.restore()
			await self?.resolveBoth(localPurchase: outcome == .restored)
			DispatchQueue.main.async { completion(outcome) }
		}
	}

	/// Buys through Adapty and settles the state the same way `restore` does — one resolve, one
	/// write, one notification — before the completion runs. Not an optimistic flag waiting for
	/// the delegate push to confirm it: a finished verdict.
	func purchase(_ productId: String, placement: String, completion: @escaping (PurchaseOutcome) -> Void) {
		guard let adapty else {
			DispatchQueue.main.async { completion(.failed) }
			return
		}
		Task { [weak self] in
			let outcome: PurchaseOutcome
			switch await adapty.buy(productId: productId, placement: placement) {
				case .success:
					outcome = .purchased
				case .cancelled:
					outcome = .cancelled
				case .failed:
					outcome = .failed
				case .retryWithStoreKit:
					// Adapty's own request failed — not the payment. The fallback stays INSIDE the
					// facade: an app that had to buy through StoreKit itself and report back would
					// be a branch leaving the single entrance and returning through the back door.
					// No Apple side wired up means there is no fallback to run, so it is a failure.
					outcome = await self?.apple?.purchase(productId: productId) ?? .failed
			}
			await self?.resolveBoth(localPurchase: outcome == .purchased)
			DispatchQueue.main.async { completion(outcome) }
		}
	}

	// MARK: - PremiumServicing: prices.
	// Two sources, one list: Adapty says WHICH products are on the placement (it owns the paywall),
	// StoreKit says what they cost (it owns the storefront). Adapty's price is what its dashboard
	// last synced; the store's is what the user is actually charged, so the store wins whenever it
	// answers.

	func product(_ productId: String, placement: String, completion: @escaping (PremiumProduct?) -> Void) {
		products(placement: placement) { completion($0.first { $0.id == productId }) }
	}

	func products(placement: String, completion: @escaping ([PremiumProduct]) -> Void) {
		guard let adapty else {
			DispatchQueue.main.async { completion([]) }
			return
		}
		let apple = self.apple
		Task {
			let listed = await adapty.products(placement: placement)
			let priced = await apple?.products(ids: Set(listed.map(\.id))) ?? [:]
			// A product the store stayed silent about (not approved yet, offline) keeps Adapty's
			// copy: a slightly staler price beats a paywall with a hole in it.
			let merged = listed.map { priced[$0.id] ?? $0 }
			DispatchQueue.main.async { completion(merged) }
		}
	}
}
