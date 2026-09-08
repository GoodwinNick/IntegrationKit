//
//  PremiumService.swift
//  IntegrationKit
//
//  Single source of truth for premium access. Adapty decides, Apple's receipt is the
//  reserve, the cache covers the offline launch. Nothing else writes the premium flag.
//

import Adapty
import Foundation

public final class PremiumService: PremiumServicing {
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

	public init(
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
	public var isPremium: Bool {
		store.cached?.isPremium ?? false
	}

	/// PM-01: seeds the cache on the first launch after the update, then publishes what we know.
	public func start() {
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
	public func refresh() {
		Task { [weak self] in
			guard let self else { return }
			async let adaptyAnswer = self.askAdapty()
			async let appleAnswer = self.askApple()
			let (access, receipt) = await (adaptyAnswer, appleAnswer)
			self.apply(adapty: access, apple: receipt)
		}
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

	/// PM-04: Adapty answered about the premium access level. The delegate push (`didLoadLatestProfile`)
	/// comes in here — a one-way entrance that is deliberately not part of the `refresh()` barrier.
	public func apply(adapty: PremiumAccess?) {
		apply(adapty: adapty, apple: nil)
	}

	/// PM-04: a StoreKit purchase or restore just succeeded — that is newer than any cached
	/// Adapty answer, so drop the verified flag and let Adapty re-confirm right after.
	public func applyLocalPurchase() {
		lock.lock()
		store.cached = store.cached.map {
			PremiumState(isPremium: $0.isPremium, source: $0.source, isVerified: false, expiresAt: $0.expiresAt)
		}
		lock.unlock()
		apply(adapty: nil, apple: true)
		// Let Adapty confirm right after. Nothing to gate: the barrier has no flags to trip.
		refresh()
	}

	private func apply(adapty: PremiumAccess?, apple: Bool?) {
		lock.lock()
		let state = PremiumResolver.resolve(adapty: adapty, apple: apple, cached: store.cached, now: Date())
		// PM-02 row 2: one store write per refresh. An answer that resolves to the state already
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

	public func hasPaywall(placement: String) -> Bool {
		adapty?.hasPaywall(placement: placement) ?? false
	}

	public func remoteValue<T>(placement: String, key: String) -> T? {
		adapty?.remoteValue(placement: placement, key: key)
	}

	public func logPaywallOpen(placement: String) {
		adapty?.logPaywallOpen(placement: placement)
	}

	// MARK: - PremiumServicing: stubs. TEMPORARY (premium rewrite step 2) — `restore`/`purchase`
	// land in step 5, `product`/`products` in step 6. No `fatalError()`, this is a public package.

	public func restore(completion: @escaping (RestoreOutcome) -> Void) {
		completion(.notImplemented)
	}

	public func purchase(_ productId: String, placement: String, completion: @escaping (PurchaseOutcome) -> Void) {
		completion(.notImplemented)
	}

	public func product(_ productId: String, placement: String, completion: @escaping (PremiumProduct?) -> Void) {
		completion(nil)
	}

	public func products(placement: String, completion: @escaping ([PremiumProduct]) -> Void) {
		completion([])
	}
}
