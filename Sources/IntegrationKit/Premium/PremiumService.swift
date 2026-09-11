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
	/// The subscription ids to look for in the Apple receipt, and the fallback list `products`
	/// prices directly when Adapty's own listing for the placement comes back empty.
	private let productIds: Set<String>
	// Guards the cached state AND its flag mirror together — see `apply`.
	// Holding it across the mirror write is safe: the store's setter posts `.premiumDidChange`
	// on `DispatchQueue.main.async`, so no observer ever runs inside this critical section.
	// Recursive anyway, so that a future synchronous notification cannot turn into a self-deadlock.
	private let lock = NSRecursiveLock()
	/// PM-01 row 4: `start()` has already run. The composition root calls it, so an app that also
	/// calls it itself would otherwise install a second push observer and repeat the seed/refresh.
	private var didStart = false
	/// PM-04 row 7: a purchase is in flight. Lifted when it settles, whichever way it ends.
	private var isPurchasing = false
	/// PM-02 rows 7-10: Adapty has not yet answered for real in this process, so the verdict still
	/// rests on what the last launch left behind. Closed by a verified answer and never reopened —
	/// from then on the profile push keeps the verdict fresh, so there is nothing left to re-ask.
	///
	/// In memory on purpose, not in `PremiumState`: stored, it would carry one launch's knowledge
	/// into a process that has asked nobody, and every new field in that struct costs a one-time
	/// migration write (the PM-02 note on `Equatable`).
	private var isQuestionOpen: Bool
	/// How long a source gets when nobody is waiting for the answer. Five seconds is a number from
	/// practice, not a guarantee Adapty documents — an app on a worse network passes its own
	/// instead of patching the package.
	private let sourceTimeout: TimeInterval
	/// PM-02: the same deadline for the call sites where a person is looking at the screen — the
	/// splash at cold start, and the paywall a purchase or a restore was just started from.
	///
	/// Being impatient there costs nothing, and that is a condition rather than a coincidence:
	/// after a purchase the verdict is held by the local-purchase mark, so Adapty's answer would
	/// be ignored anyway, and at start an Adapty that did not make it leaves the question open —
	/// the next foreground asks again, patiently. Never longer than `sourceTimeout`, or the two
	/// names would be lying.
	private let waitingTimeout: TimeInterval

	init(
		store: PremiumStateStoring = UserDefaultsPremiumStore(),
		adapty: AdaptyPremiumProviding? = nil,
		apple: AppleSubscribing? = nil,
		levels: Set<String> = ["premium"],
		sourceTimeout: TimeInterval = 5,
		waitingTimeout: TimeInterval = 2,
		productIds: Set<String> = []
	) {
		self.store = store
		self.adapty = adapty
		self.apple = apple
		self.levels = levels
		self.sourceTimeout = sourceTimeout
		self.waitingTimeout = min(waitingTimeout, sourceTimeout)
		self.productIds = productIds
		// PM-02 row 9: an app built without Adapty has nobody to wait for. Its question is closed
		// before it is ever asked, so returning to the foreground costs it nothing.
		isQuestionOpen = adapty != nil
	}

	/// Convenience read for call sites that just need the current answer.
	var isPremium: Bool {
		store.cached?.isPremium ?? false
	}

	/// PM-01: seeds the cache on the first launch after the update, then publishes what we know.
	///
	/// PM-01 row 4: idempotent. A second call returns without touching anything — one push
	/// observer, one seed, one first refresh, no matter how many times the app asks.
	func start() {
		lock.lock()
		guard !didStart else {
			lock.unlock()
			return
		}
		didStart = true
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

		adapty?.premiumObserver = { [weak self] profile, isVerified in
			guard let self else { return }
			self.apply(adapty: PremiumAccess(profile: profile, levels: self.levels, isVerified: isVerified))
		}
		// PM-02: the impatient deadline. The splash is waiting behind this one, and a source that
		// does not make it leaves the question open rather than unanswered for good.
		refresh(timeout: waitingTimeout)
	}

	/// PM-02: one barrier instead of two in-flight flags. Both sources are asked at once and the
	/// verdict is taken when both have answered — one resolve, one store write, one notification.
	/// A source that never answers costs its own deadline and nothing more: there is no flag left
	/// raised, so it cannot block any later `refresh()`.
	///
	/// An intermediate state no longer exists either: the receipt cannot land first, flash a
	/// value at the UI, and be overwritten by Adapty a moment later.
	func refresh() {
		refresh(timeout: sourceTimeout)
	}

	/// The same barrier with the deadline the call site chose — `start()` is the impatient one.
	private func refresh(timeout: TimeInterval) {
		Task { [weak self] in await self?.resolveBoth(timeout: timeout) }
	}

	/// PM-02 row 7: the app came back to the foreground. A barrier where nobody answered leaves the
	/// verdict resting on the last launch's memory and re-asks nobody — a cold start with no network
	/// would otherwise cost a whole session, either without the premium the user paid for elsewhere
	/// or with one that has since expired. So while the question is still open, coming back asks
	/// again; once Adapty has answered, the push keeps the verdict fresh and this does nothing.
	func refreshIfUnanswered() {
		lock.lock()
		let open = isQuestionOpen
		lock.unlock()
		guard open else { return }
		refresh()
	}

	/// PM-08 row 5: the payment queue handed over a purchase. The same barrier as `refresh()`,
	/// marked as a local purchase — Apple's receipt can still be a version behind a transaction
	/// finished seconds ago, and a cached verified `inactive` must not swallow it either.
	func purchaseDelivered() {
		Task { [weak self] in await self?.resolveBoth(localPurchase: true) }
	}

	/// The barrier itself, awaitable. `refresh()` fires it and forgets; `restore`/`purchase` await
	/// it, which is what lets their completion run with the verdict already stored.
	///
	/// `localPurchase` marks that a purchase or a StoreKit restore has just gone through on this
	/// device. That is a receipt saying yes, newer than any check we could run — see `apply`.
	private func resolveBoth(localPurchase: Bool = false, timeout: TimeInterval? = nil) async {
		let deadline = timeout ?? sourceTimeout
		async let adaptyAnswer = askAdapty(timeout: deadline)
		async let appleAnswer = askApple(timeout: deadline)
		let (access, receipt) = await (adaptyAnswer, appleAnswer)
		apply(adapty: access, apple: receipt, localPurchase: localPurchase)
	}

	/// `nil` means Adapty did not answer — an error, no source at all, or slower than the deadline.
	/// Never "no premium": that is `PremiumAccess(isActive: false)`.
	private func askAdapty(timeout: TimeInterval) async -> PremiumAccess? {
		guard let adapty else { return nil }
		let profile = await withTimeout(timeout) { await adapty.profile() }
		return profile.flatMap { $0 }.map { PremiumAccess(profile: $0, levels: levels) }
	}

	/// `nil` means the receipt could not be checked, in time or at all — never "no subscription".
	private func askApple(timeout: TimeInterval) async -> ReceiptAnswer? {
		guard let apple else { return nil }
		return await withTimeout(timeout) { await apple.checkReceipt() }.flatMap { $0 }
	}

	/// PM-06: Adapty answered about the premium access level. The delegate push (`didLoadLatestProfile`)
	/// comes in here — a one-way entrance that is deliberately not part of the `refresh()` barrier.
	func apply(adapty: PremiumAccess?) {
		apply(adapty: adapty, apple: nil)
	}

	private func apply(adapty: PremiumAccess?, apple: ReceiptAnswer?, localPurchase: Bool = false) {
		lock.lock()
		// PM-02 row 8: only a verified answer closes the question. The profile the SDK pushes out of
		// its own storage on activation is the last launch remembered, not a check — treating it as
		// an answer would cancel the very retry this exists for. The receipt does not close it either:
		// it cannot see a subscription bought outside the App Store, and it needs no network anyway.
		if adapty?.isVerified == true {
			isQuestionOpen = false
		}
		// The local-purchase mark and its cache-demotion trick now live entirely in
		// PremiumResolver.resolve — this just hands over what it has and takes back the verdict.
		let state = PremiumResolver.resolve(adapty: adapty, apple: apple, cached: store.cached, localPurchase: localPurchase, now: Date())
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

	func paywallState(placement: String) -> PaywallState {
		adapty?.paywallState(placement: placement) ?? .unavailable
	}

	func remoteValue<T>(placement: String, key: String) -> RemoteValue<T> {
		adapty?.remoteValue(placement: placement, key: key) ?? .notReady
	}

	func logPaywallOpen(placement: String) {
		adapty?.logPaywallOpen(placement: placement)
	}

	/// Everything the package could not make work and no retry will fix — an empty key, a device id
	/// that arrived too late, a placement that does not exist, a product the paywall does not sell.
	/// Each cause appears once. Print it in DEBUG, ship it to Crashlytics, or assert on it in a test.
	var configurationIssues: [String] {
		ConfigurationIssues.shared.all
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
		// PM-02: the paywall the restore was started from is still on screen, so the barrier behind
		// it gets the impatient deadline.
		let deadline = waitingTimeout
		Task { [weak self] in
			// No timeout around this one on purpose: StoreKit may be showing an account prompt,
			// and there is no continuation to leak — the deadline guard belongs to the sources.
			let outcome = await apple.restore()
			await self?.resolveBoth(localPurchase: outcome == .restored, timeout: deadline)
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
		// PM-04 row 7: one purchase at a time. A second call while the first is still in flight is
		// refused here, before the SDK sees it — two payment dialogs stacked on each other is the
		// defect, and neither Adapty nor StoreKit stops them from being asked for.
		lock.lock()
		let wasPurchasing = isPurchasing
		isPurchasing = true
		lock.unlock()
		guard !wasPurchasing else {
			DispatchQueue.main.async { completion(.failed) }
			return
		}
		// PM-02: same as `restore` — the user just paid and is watching the paywall wait. And the
		// verdict behind this barrier is held by the mark anyway, so a slow Adapty has nothing to
		// add to it.
		let deadline = waitingTimeout
		Task { [weak self] in
			let outcome: PurchaseOutcome
			// Whether this device just paid for something. Drives the local-purchase mark, which
			// holds premium open against an Adapty denial recorded before the payment landed.
			var didPay = false
			switch await adapty.buy(productId: productId, placement: placement) {
				case .success:
					outcome = .purchased
					didPay = true
				case .cancelled:
					outcome = .cancelled
				case .pending:
					// Ask to Buy waiting for a parent, or a purchase call that never came back inside
					// its deadline. Neither bought nor refused: no access, no error, and no second
					// attempt offered — the answer arrives on its own through the payment queue and
					// the profile push (AD-04 row 1).
					outcome = .pending
				case .unavailable:
					// Permanent for this device, this storefront, or this product: parental controls,
					// a product missing from the store, a promotional offer the store refuses to sign.
					// Falling back to StoreKit would buy that discounted product at full price
					// (AD-04 rows 3 and 5).
					outcome = .unavailable
				case .failed:
					outcome = .failed
				case .retryWithStoreKit:
					// Adapty's own request failed — not the payment. The fallback stays INSIDE the
					// facade: an app that had to buy through StoreKit itself and report back would
					// be a branch leaving the single entrance and returning through the back door.
					// No Apple side wired up means there is no fallback to run, so it is a failure.
					outcome = await self?.apple?.purchase(productId: productId) ?? .failed
					didPay = outcome == .purchased
					// Adapty just failed to serve the purchase, so it does not know about it yet —
					// ask it to upload the local receipt and refresh its profile, closing the window
					// the mark exists to cover. Only when the fallback itself actually succeeded.
					if didPay {
						adapty.syncReceipt()
					}
			}
			if didPay {
				// PM-04 row 14: the placement the money came from, written by the package because it
				// is the only side that has both halves — the app knows the placement but not that
				// Apple charged, the Adapty layer knows neither once the fallback took over. Same
				// `didPay` as the mark above on purpose: one condition, not two that drift apart.
				adapty.setProfileValue(value: placement, key: "purchasePlace")
			}
			await self?.resolveBoth(localPurchase: didPay, timeout: deadline)
			self?.endPurchase()
			DispatchQueue.main.async { completion(outcome) }
		}
	}

	/// The single exit of `purchase` — bought, cancelled, failed and the StoreKit fallback all come
	/// through here, so a finished purchase can never leave the next one blocked.
	private func endPurchase() {
		lock.lock()
		isPurchasing = false
		lock.unlock()
	}

	// MARK: - PremiumServicing: prices.
	// Two sources, one list: Adapty says WHICH products are on the placement (it owns the paywall),
	// StoreKit says what they cost (it owns the storefront). Adapty's price is what its dashboard
	// last synced; the store's is what the user is actually charged, so the store wins whenever it
	// answers.

	func product(_ productId: String, placement: String, completion: @escaping (PremiumProduct?) -> Void) {
		products(placement: placement) { completion($0.first { $0.id == productId }) }
	}

	/// PM-07 row 12: `isActive` is asked for here, not inferred. A layer that never came up answers
	/// `.notReady` about every placement — letter for letter what a live layer says while its paywall
	/// is still on the way — so the fallback below cannot tell the two apart on its own. The fallback
	/// is for "the paywall did not load"; a layer that is off for the run sells nothing at all,
	/// because `AdaptyService.buyProduct` refuses on this same flag, and pricing the configured ids
	/// there would draw a paywall of real prices with every button dead. An empty list is the honest
	/// answer, and it is the answer an app shipped without monetisation wants anyway.
	func products(placement: String, completion: @escaping ([PremiumProduct]) -> Void) {
		guard let adapty, adapty.isActive else {
			DispatchQueue.main.async { completion([]) }
			return
		}
		let apple = self.apple
		let productIds = self.productIds
		Task {
			let listed: [PremiumProduct]
			switch await adapty.products(placement: placement) {
				case .products(let products):
					listed = products
				case .notReady:
					debugLog(tag: "PremiumService", "'\(placement)' has no paywall yet — pricing the configured ids from the store")
					listed = []
				case .failed:
					debugLog(tag: "PremiumService", level: .error, "Adapty could not list the products of '\(placement)' — pricing the configured ids from the store")
					listed = []
			}
			if listed.isEmpty {
				// The placement did not load — an unloaded paywall must not leave a screen with no
				// prices at all. Fall back to the ids handed to `init` and price them from the store
				// directly; an id the store also stayed silent about is simply not in the result.
				let priced = await apple?.products(ids: productIds) ?? [:]
				DispatchQueue.main.async { completion(Array(priced.values)) }
				return
			}
			let priced = await apple?.products(ids: Set(listed.map(\.id))) ?? [:]
			// A product the store stayed silent about (not approved yet, offline) keeps Adapty's
			// copy: a slightly staler price beats a paywall with a hole in it.
			let merged = listed.map { priced[$0.id] ?? $0 }
			DispatchQueue.main.async { completion(merged) }
		}
	}
}
