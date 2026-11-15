//
//  PremiumBarrierCheck.swift
//  IntegrationKit
//
//  PM-02 (the `refresh()` barrier) plus restore/purchase — spec section 6, points 1-5, with a
//  negative restore, a purchase, the in-facade StoreKit fallback (spec 3.2) and prices through
//  the facade (spec 3.4) on top.
//  Run:  ./Checks/premium-barrier-check.sh
//

import Adapty
import Foundation

/// Counts what the real `UserDefaultsPremiumStore` does: every write to `cached`, and a
/// notification only when the mirror flag actually changes value.
final class SpyStore: PremiumStateStoring {
	private let lock = NSLock()
	private var state: PremiumState?
	private var flag: Bool
	private var cachedWrites = 0
	private var notifications = 0

	init(cached: PremiumState? = nil, premium: Bool = false) {
		state = cached
		flag = premium
	}

	var writes: Int {
		lock.lock()
		defer { lock.unlock() }
		return cachedWrites
	}

	var notified: Int {
		lock.lock()
		defer { lock.unlock() }
		return notifications
	}

	var cached: PremiumState? {
		get {
			lock.lock()
			defer { lock.unlock() }
			return state
		}
		set {
			lock.lock()
			defer { lock.unlock() }
			cachedWrites += 1
			state = newValue
		}
	}

	var premium: Bool {
		get {
			lock.lock()
			defer { lock.unlock() }
			return flag
		}
		set {
			lock.lock()
			defer { lock.unlock() }
			guard flag != newValue else { return }
			flag = newValue
			notifications += 1
		}
	}
}

/// An Adapty that answers whatever it is told, after however long it is told.
final class FakeAdapty: AdaptyPremiumProviding {
	/// The `Bool` is provenance — `false` for the SDK's first, disk-cached push (AD-05 row 2). Every
	/// push in this file passes `true`: these rows are about the barrier, not about provenance.
	var premiumObserver: ((AdaptyProfile, Bool) -> Void)? {
		didSet { onObserverSet?() }
	}
	/// Fires the moment `start()` installs its observer — case 14 reads the store from inside it to
	/// see what was already published by then.
	var onObserverSet: (() -> Void)?
	var answer: AdaptyProfile?
	var delay: TimeInterval
	var buyResult: PurchaseVerdict = .failed
	var catalogue: [PremiumProduct] = []
	/// How many times the facade has asked for a profile. Case 23 waits on it: a race case that
	/// pushes before the slow barrier has actually left the gate would be testing the opposite
	/// order, so the count is what makes "the refresh is in flight" a fact rather than a sleep.
	var asks: Int {
		askLock.lock()
		defer { askLock.unlock() }
		return askCount
	}

	private let askLock = NSLock()
	private var askCount = 0

	init(answer: AdaptyProfile?, delay: TimeInterval = 0) {
		self.answer = answer
		self.delay = delay
	}

	func profile() async -> AdaptyProfile? {
		countAsk()
		if delay > 0 {
			try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
		}
		return answer
	}

	/// `NSLock` is unavailable from an async context in Swift 6 language mode, so the counting
	/// happens in a synchronous helper.
	private func countAsk() {
		askLock.lock()
		askCount += 1
		askLock.unlock()
	}

	func products(placement: String) async -> AdaptyProductsAnswer {
		catalogue.isEmpty ? .notReady : .products(catalogue)
	}

	func buy(productId: String, placement: String) async -> PurchaseVerdict { buyResult }
	func remoteValue<T>(placement: String, key: String) -> RemoteValue<T> { .notReady }
	func logPaywallOpen(placement: String) {}
	func hasPaywall(placement: String) -> Bool { false }
	func paywallState(placement: String) -> PaywallState { .unavailable }
	func syncReceipt() {}
}

/// The Apple side, same idea.
final class FakeApple: AppleSubscribing {
	var receipt: ReceiptAnswer?
	var delay: TimeInterval
	var restoreResult: RestoreOutcome = .nothingToRestore
	var purchaseResult: PurchaseOutcome = .failed
	/// Set by `purchase` — case 8 asserts the fallback was actually reached, not just that the
	/// outcome happened to match.
	var purchasedProductId: String?
	/// What the store answers about prices. An id missing from here is the store staying silent.
	var catalogue: [String: PremiumProduct] = [:]
	/// The ids the facade actually asked the store about — case 11 checks it asks for the ones
	/// Adapty listed, not for some list of its own.
	var askedForIds: Set<String>?

	init(receipt: ReceiptAnswer?, delay: TimeInterval = 0) {
		self.receipt = receipt
		self.delay = delay
	}

	func checkReceipt() async -> ReceiptAnswer? {
		if delay > 0 {
			try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
		}
		return receipt
	}

	func restore() async -> RestoreOutcome { restoreResult }

	func purchase(productId: String) async -> PurchaseOutcome {
		purchasedProductId = productId
		return purchaseResult
	}

	func products(ids: Set<String>) async -> [String: PremiumProduct] {
		askedForIds = ids
		return catalogue.filter { ids.contains($0.key) }
	}
}

@main
enum PremiumBarrierCheck {
	static let hour: TimeInterval = 3600

	static func profile(active: Bool, expiresAt: Date? = nil) -> AdaptyProfile {
		AdaptyProfile(accessLevels: [
			"premium": AdaptyProfile.AccessLevel(id: "premium", isActive: active, isLifetime: false, expiresAt: expiresAt)
		])
	}

	/// Polls instead of awaiting: `refresh()` is fire-and-forget by contract, so the only thing
	/// an observer can do is watch the store. Pumps the run loop rather than sleeping, because
	/// `restore`/`purchase` hand their completion back on the main queue.
	@discardableResult
	static func wait(_ seconds: TimeInterval = 2, for condition: () -> Bool) -> Bool {
		let deadline = Date().addingTimeInterval(seconds)
		while Date() < deadline {
			if condition() { return true }
			RunLoop.current.run(until: Date().addingTimeInterval(0.005))
		}
		return condition()
	}

	static func main() {
		let now = Date()

		// 1. Both sources answer, the receipt first — exactly one store write and one
		//    notification, and the verdict is Adapty's. Two independent `apply`s would write
		//    twice: the receipt's intermediate value, then Adapty's overwrite.
		let store = SpyStore()
		let adapty = FakeAdapty(answer: profile(active: true, expiresAt: now + hour), delay: 0.15)
		let apple = FakeApple(receipt: ReceiptAnswer(isActive: true, expiresAt: nil), delay: 0.01)
		let service = PremiumService(store: store, adapty: adapty, apple: apple, levels: ["premium"], sourceTimeout: 1)
		service.refresh()
		assert(wait { store.writes > 0 }, "case 1: the barrier must produce a verdict")
		// Long enough for a second, wrong write to show up if the barrier is not holding.
		Thread.sleep(forTimeInterval: 0.3)
		assert(store.writes == 1, "case 1: both sources answered — exactly one store write, got \(store.writes)")
		assert(store.notified == 1, "case 1: exactly one .premiumDidChange, got \(store.notified)")
		assert(store.cached?.source == .adapty, "case 1: Adapty decides when it answered")
		assert(store.cached?.isVerified == true && store.cached?.isPremium == true, "case 1: Adapty active means verified premium")

		// 2. Adapty stays silent, the receipt says yes — verdict by receipt, and no `awaiting`
		//    block is left behind: the next refresh still runs.
		let silentStore = SpyStore()
		let silentAdapty = FakeAdapty(answer: nil)
		let receiptApple = FakeApple(receipt: ReceiptAnswer(isActive: true, expiresAt: nil))
		let silentService = PremiumService(store: silentStore, adapty: silentAdapty, apple: receiptApple, levels: ["premium"], sourceTimeout: 1)
		silentService.refresh()
		assert(wait { silentStore.cached?.isPremium == true }, "case 2: a silent Adapty must not stop the receipt verdict")
		assert(silentStore.cached?.source == .apple && silentStore.cached?.isVerified == false, "case 2: the receipt grants unverified premium")
		// The observable for "the second run really happened" is a grant, not a denial: since
		// 2026-09-11 a denial resolves exactly like silence, so it would leave the verdict untouched
		// and this case would pass whether the barrier reran or stayed shut.
		silentAdapty.answer = profile(active: true)
		silentService.refresh()
		assert(wait { silentStore.cached?.source == .adapty }, "case 2: a second refresh must run after Adapty went silent once")

		// 3. Nobody answers — nothing changes, and the next refresh still works. This is the
		//    exact scenario the two-flag version dead-locked on.
		let held = PremiumState(isPremium: true, source: .apple, isVerified: false)
		let mutedStore = SpyStore(cached: held, premium: true)
		let mutedAdapty = FakeAdapty(answer: nil)
		let mutedApple = FakeApple(receipt: nil)
		let mutedService = PremiumService(store: mutedStore, adapty: mutedAdapty, apple: mutedApple, levels: ["premium"], sourceTimeout: 1)
		mutedService.refresh()
		Thread.sleep(forTimeInterval: 0.2)
		assert(mutedStore.writes == 0, "case 3: nobody answered — nothing to write, got \(mutedStore.writes) writes")
		assert(mutedStore.notified == 0, "case 3: nobody answered — nothing to notify about")
		assert(mutedStore.cached == held, "case 3: the held state must survive a refresh nobody answered")
		mutedAdapty.answer = profile(active: true, expiresAt: now + hour)
		mutedService.refresh()
		assert(wait { mutedStore.cached?.isVerified == true }, "case 3: a refresh after both sources went silent must still work")

		// 4. The timeout fires — the verdict comes from whoever answered in time, and it comes
		//    on the timeout's schedule, not the stuck source's.
		let timeoutStore = SpyStore()
		let stuckAdapty = FakeAdapty(answer: profile(active: false), delay: 3)
		let quickApple = FakeApple(receipt: ReceiptAnswer(isActive: true, expiresAt: nil), delay: 0.01)
		let timeoutService = PremiumService(store: timeoutStore, adapty: stuckAdapty, apple: quickApple, levels: ["premium"], sourceTimeout: 0.2)
		let started = Date()
		timeoutService.refresh()
		assert(wait(1.5) { timeoutStore.writes > 0 }, "case 4: a source that never answers must not hold the verdict")
		let elapsed = Date().timeIntervalSince(started)
		assert(elapsed < 1.5, "case 4: the verdict must arrive on the timeout, took \(elapsed)s")
		assert(timeoutStore.cached?.isPremium == true && timeoutStore.cached?.source == .apple, "case 4: the verdict is built from what did arrive")

		// 5. Spec section 6 point 5, and the defect the rewrite exists for: restore succeeds and
		//    premium is already on INSIDE the completion — nothing left for the caller to chase.
		//    The starting cache is the nasty one: a verified `inactive` Adapty gave us before the
		//    restore, which resolver step 2 hands straight back unless the local restore demotes
		//    it first. Adapty stays silent here, so the verdict has to come from the restore.
		let staleDenial = PremiumState(isPremium: false, source: .adapty, isVerified: true)
		let restoreStore = SpyStore(cached: staleDenial)
		let restoreAdapty = FakeAdapty(answer: nil)
		let restoreApple = FakeApple(receipt: nil)
		restoreApple.restoreResult = .restored
		let restoreService = PremiumService(store: restoreStore, adapty: restoreAdapty, apple: restoreApple, levels: ["premium"], sourceTimeout: 1)
		var restoreOutcome: RestoreOutcome?
		var premiumInsideRestore: Bool?
		restoreService.restore { outcome in
			premiumInsideRestore = restoreService.isPremium
			restoreOutcome = outcome
		}
		assert(wait { restoreOutcome != nil }, "case 5: restore must call back")
		assert(restoreOutcome == .restored, "case 5: the StoreKit answer is passed through untouched")
		assert(premiumInsideRestore == true, "case 5: premium must be on BEFORE the completion returns")
		assert(restoreStore.cached?.isPremium == true && restoreStore.cached?.source == .apple, "case 5: a restored purchase grants unverified premium")
		assert(restoreStore.notified == 1, "case 5: exactly one .premiumDidChange, got \(restoreStore.notified)")

		// 6. The negative: nothing to restore grants nothing, and costs neither a write nor a
		//    notification. Forcing the local-purchase receipt on every restore shows up right here.
		let emptyStore = SpyStore(cached: .free)
		let emptyService = PremiumService(
			store: emptyStore,
			adapty: FakeAdapty(answer: nil),
			apple: FakeApple(receipt: nil),
			levels: ["premium"],
			sourceTimeout: 1
		)
		var emptyOutcome: RestoreOutcome?
		emptyService.restore { emptyOutcome = $0 }
		assert(wait { emptyOutcome != nil }, "case 6: restore must call back")
		assert(emptyOutcome == .nothingToRestore, "case 6: nothing was restored")
		assert(emptyService.isPremium == false, "case 6: nothing to restore must not grant premium")
		assert(emptyStore.writes == 0, "case 6: nothing changed — nothing to write, got \(emptyStore.writes)")
		assert(emptyStore.notified == 0, "case 6: nothing changed — nothing to notify about, got \(emptyStore.notified)")

		// 7. Purchase settles through the same barrier: the completion sees a finished verdict,
		//    not an optimistic flag waiting for Adapty's push to confirm it.
		let buyStore = SpyStore()
		let buyAdapty = FakeAdapty(answer: profile(active: true, expiresAt: now + hour))
		buyAdapty.buyResult = .success
		let buyService = PremiumService(store: buyStore, adapty: buyAdapty, apple: FakeApple(receipt: nil), levels: ["premium"], sourceTimeout: 1)
		var buyOutcome: PurchaseOutcome?
		var premiumInsidePurchase: Bool?
		buyService.purchase("year.sub", placement: "main") { outcome in
			premiumInsidePurchase = buyService.isPremium
			buyOutcome = outcome
		}
		assert(wait { buyOutcome != nil }, "case 7: purchase must call back")
		assert(buyOutcome == .purchased, "case 7: the Adapty answer is passed through untouched")
		assert(premiumInsidePurchase == true, "case 7: premium must be on BEFORE the completion returns")
		assert(buyStore.writes == 1, "case 7: one write, got \(buyStore.writes)")
		assert(buyStore.notified == 1, "case 7: one .premiumDidChange, got \(buyStore.notified)")
		assert(buyStore.cached?.source == .adapty && buyStore.cached?.isVerified == true, "case 7: Adapty confirmed the purchase in the same round trip")

		// 8. Adapty could not run the purchase and asked for the StoreKit fallback. The fallback
		//    happens INSIDE the facade — `retryWithStoreKit` never reaches the caller, the settled
		//    result of the Apple purchase does, and the state is resolved the same single way.
		let fallbackStore = SpyStore()
		let fallbackAdapty = FakeAdapty(answer: nil)
		fallbackAdapty.buyResult = .retryWithStoreKit
		let fallbackApple = FakeApple(receipt: nil)
		fallbackApple.purchaseResult = .purchased
		let fallbackService = PremiumService(store: fallbackStore, adapty: fallbackAdapty, apple: fallbackApple, levels: ["premium"], sourceTimeout: 1)
		var fallbackOutcome: PurchaseOutcome?
		var premiumInsideFallback: Bool?
		fallbackService.purchase("year.sub", placement: "main") { outcome in
			premiumInsideFallback = fallbackService.isPremium
			fallbackOutcome = outcome
		}
		assert(wait { fallbackOutcome != nil }, "case 8: purchase must call back")
		assert(fallbackApple.purchasedProductId == "year.sub", "case 8: the StoreKit fallback must be called by the package, with the same product")
		assert(fallbackOutcome == .purchased, "case 8: the caller hears the fallback's result, never a retry request")
		assert(premiumInsideFallback == true, "case 8: a fallback purchase turns premium on before the completion returns")
		assert(fallbackStore.writes == 1, "case 8: one write, got \(fallbackStore.writes)")
		assert(fallbackStore.notified == 1, "case 8: one .premiumDidChange, got \(fallbackStore.notified)")
		assert(fallbackStore.cached?.source == .apple && fallbackStore.cached?.isVerified == false, "case 8: a local purchase Adapty has not confirmed is unverified premium")

		// 9. Same request, but StoreKit refused too — a failure, and premium stays off. Without
		//    this the fallback could grant premium on any Adapty hiccup.
		let deniedStore = SpyStore(cached: .free)
		let deniedAdapty = FakeAdapty(answer: nil)
		deniedAdapty.buyResult = .retryWithStoreKit
		let deniedApple = FakeApple(receipt: nil)
		deniedApple.purchaseResult = .failed
		let deniedService = PremiumService(store: deniedStore, adapty: deniedAdapty, apple: deniedApple, levels: ["premium"], sourceTimeout: 1)
		var deniedOutcome: PurchaseOutcome?
		deniedService.purchase("year.sub", placement: "main") { deniedOutcome = $0 }
		assert(wait { deniedOutcome != nil }, "case 9: purchase must call back")
		assert(deniedOutcome == .failed, "case 9: a failed fallback is a failed purchase")
		assert(deniedService.isPremium == false, "case 9: a failed fallback must not grant premium")
		assert(deniedStore.writes == 0, "case 9: nothing changed — nothing to write, got \(deniedStore.writes)")

		// 10. Prices come out of the facade, not out of Adapty (spec 3.4), and `product` picks
		//     from exactly the same list `products` hands over.
		let priceAdapty = FakeAdapty(answer: nil)
		priceAdapty.catalogue = [
			PremiumProduct(id: "year.sub", localizedTitle: "Year", localizedPrice: "$29.99", price: 29.99, currencyCode: "USD", subscriptionPeriod: PremiumPeriod(unit: .year, numberOfUnits: 1), introductoryOffer: nil),
			PremiumProduct(id: "week.sub", localizedTitle: "Week", localizedPrice: "$4.99", price: 4.99, currencyCode: "USD", subscriptionPeriod: PremiumPeriod(unit: .week, numberOfUnits: 1), introductoryOffer: nil),
		]
		let priceService = PremiumService(store: SpyStore(), adapty: priceAdapty, apple: nil, levels: ["premium"], sourceTimeout: 1)
		var listed: [PremiumProduct]?
		priceService.products(placement: "main") { listed = $0 }
		assert(wait { listed != nil }, "case 10: products must call back")
		assert(listed?.map(\.id) == ["year.sub", "week.sub"], "case 10: the facade hands over what Adapty loaded")
		var picked: PremiumProduct??
		priceService.product("week.sub", placement: "main") { picked = $0 }
		assert(wait { picked != nil }, "case 10: product must call back")
		assert(picked??.localizedPrice == "$4.99", "case 10: product picks by id out of the same list")
		var missing: PremiumProduct??
		priceService.product("month.sub", placement: "main") { missing = $0 }
		assert(wait { missing != nil }, "case 10: product must call back for an unknown id too")
		assert(missing! == nil, "case 10: an id the placement does not carry is nil, not the first product")

		// 11. Two sources for one list: Adapty says which products the placement carries, the
		//     store says what they cost. The store's price wins where it answered; an id it stayed
		//     silent about keeps Adapty's copy instead of falling out of the paywall.
		let mixedAdapty = FakeAdapty(answer: nil)
		mixedAdapty.catalogue = [
			PremiumProduct(id: "year.sub", localizedTitle: "Year", localizedPrice: "$29.99", price: 29.99, currencyCode: "USD", subscriptionPeriod: PremiumPeriod(unit: .year, numberOfUnits: 1), introductoryOffer: nil),
			PremiumProduct(id: "week.sub", localizedTitle: "Week", localizedPrice: "$4.99", price: 4.99, currencyCode: "USD", subscriptionPeriod: PremiumPeriod(unit: .week, numberOfUnits: 1), introductoryOffer: nil),
		]
		let storeApple = FakeApple(receipt: nil)
		storeApple.catalogue = [
			// The store knows this one, and knows it costs something else in this storefront.
			"year.sub": PremiumProduct(id: "year.sub", localizedTitle: "Year", localizedPrice: "€34,99", price: 34.99, currencyCode: "EUR", subscriptionPeriod: PremiumPeriod(unit: .year, numberOfUnits: 1), introductoryOffer: nil),
			// Never asked for: not on this placement.
			"month.sub": PremiumProduct(id: "month.sub", localizedTitle: "Month", localizedPrice: "€9,99", price: 9.99, currencyCode: "EUR", subscriptionPeriod: PremiumPeriod(unit: .month, numberOfUnits: 1), introductoryOffer: nil),
		]
		let mixedService = PremiumService(store: SpyStore(), adapty: mixedAdapty, apple: storeApple, levels: ["premium"], sourceTimeout: 1)
		var mixed: [PremiumProduct]?
		mixedService.products(placement: "main") { mixed = $0 }
		assert(wait { mixed != nil }, "case 11: products must call back")
		assert(storeApple.askedForIds == ["year.sub", "week.sub"], "case 11: the store is asked exactly about the placement's ids, got \(storeApple.askedForIds.map(String.init(describing:)) ?? "nil")")
		assert(mixed?.map(\.id) == ["year.sub", "week.sub"], "case 11: Adapty decides the composition and its order")
		assert(mixed?.first?.localizedPrice == "€34,99" && mixed?.first?.currencyCode == "EUR", "case 11: the store's price wins where the store answered")
		assert(mixed?.last?.localizedPrice == "$4.99", "case 11: an id the store stayed silent about keeps Adapty's price")

		// 12. PM-01 row 1: the migration seed. An app moving onto the package carries only the legacy
		//     `true` flag and no structured cache — `start()` has to turn that into unverified premium
		//     from `.legacy`, not into a free state that shows a paywall to a paying user.
		let seedStore = SpyStore(cached: nil, premium: true)
		let seedService = PremiumService(store: seedStore, adapty: FakeAdapty(answer: nil), apple: FakeApple(receipt: nil), levels: ["premium"], sourceTimeout: 1)
		seedService.start()
		assert(
			seedStore.cached == PremiumState(isPremium: true, source: .legacy, isVerified: false),
			"case 12: the legacy flag must seed exactly PremiumState(isPremium: true, source: .legacy, isVerified: false, expiresAt: nil), got \(String(describing: seedStore.cached))"
		)
		// Long enough for `start()`'s own refresh to land — with both sources silent it must add
		// nothing on top of the seed.
		Thread.sleep(forTimeInterval: 0.3)
		assert(seedStore.writes == 1, "case 12: the seed is the only write a silent start makes, expected 1, got \(seedStore.writes)")
		assert(seedService.isPremium == true, "case 12: the seeded state must read back as premium, got \(seedService.isPremium)")

		// 13. PM-01 row 2: a cache that no longer decodes (the verdict schema changed between package
		//     versions) must read as "no cache", not crash and not fabricate a state. The REAL
		//     `UserDefaultsPremiumStore` is what carries that behaviour, so this row uses it against a
		//     throwaway suite instead of `SpyStore`.
		let suiteName = "com.integrationkit.checks.pm01row2"
		let suite = UserDefaults(suiteName: suiteName)
		assert(suite != nil, "case 13: the throwaway UserDefaults suite must open")
		let realStore = UserDefaultsPremiumStore(defaults: suite!, stateKey: "premiumStateKey", flagKey: "premiumKey")
		// First prove the wiring: a valid state written through the store reads back. Without this the
		// `nil` below could just as well come from reading the wrong key.
		let written = PremiumState(isPremium: true, source: .adapty, isVerified: true, expiresAt: now + hour)
		realStore.cached = written
		assert(realStore.cached == written, "case 13: a valid state must round-trip through the real store, got \(String(describing: realStore.cached))")
		suite!.set(Data("{ this is not a PremiumState".utf8), forKey: "premiumStateKey")
		assert(suite!.data(forKey: "premiumStateKey") != nil, "case 13: the corrupted payload must actually be in the defaults")
		assert(realStore.cached == nil, "case 13: a cache that does not decode must read as exactly nil, got \(String(describing: realStore.cached))")
		suite!.removePersistentDomain(forName: suiteName)

		// 14. PM-01 row 3 and PM-06 row 1 (the same scenario, one case): the Adapty push subscription
		//     is installed AFTER the cache is published, so a push firing at the instant of
		//     subscription cannot be overwritten by a cache publication that has not happened yet.
		//     `onObserverSet` fires exactly when `start()` assigns the observer.
		let orderStore = SpyStore()
		let orderAdapty = FakeAdapty(answer: nil)
		let orderService = PremiumService(store: orderStore, adapty: orderAdapty, apple: FakeApple(receipt: nil), levels: ["premium"], sourceTimeout: 1)
		let pushedExpiry = now + hour
		var cachedAtSubscription: PremiumState??
		var writesAtSubscription = -1
		orderAdapty.onObserverSet = { [weak orderAdapty] in
			cachedAtSubscription = orderStore.cached
			writesAtSubscription = orderStore.writes
			// The nastiest timing there is: the push lands inside the assignment itself.
			orderAdapty?.premiumObserver?(profile(active: true, expiresAt: pushedExpiry), true)
		}
		orderService.start()
		assert(cachedAtSubscription != nil, "case 14: the observer must be installed at all")
		assert(cachedAtSubscription! != nil, "case 14: the cache must already be published when the observer is installed, got nil")
		assert(writesAtSubscription == 1, "case 14: exactly 1 store write (the seed) must precede the subscription, got \(writesAtSubscription)")
		Thread.sleep(forTimeInterval: 0.3)
		assert(
			orderStore.cached == PremiumState(isPremium: true, source: .adapty, isVerified: true, expiresAt: pushedExpiry),
			"case 14: a push during start() must survive, expected the pushed verified premium, got \(String(describing: orderStore.cached))"
		)
		assert(orderStore.writes == 2, "case 14: seed then push — exactly 2 writes, got \(orderStore.writes)")
		assert(orderStore.notified == 1, "case 14: exactly 1 .premiumDidChange, got \(orderStore.notified)")

		// 15. PM-01 row 5: Adapty was never activated (empty key), so the package holds no Adapty side
		//     at all and no Apple side either. Both `guard let` returns give `nil` — "did not answer" —
		//     which must leave the verdict exactly as it was, never rewrite it to "no premium".
		let heldByCache = PremiumState(isPremium: true, source: .adapty, isVerified: true, expiresAt: now + hour)
		let unwiredStore = SpyStore(cached: heldByCache, premium: true)
		let unwiredService = PremiumService(store: unwiredStore, adapty: nil, apple: nil, levels: ["premium"], sourceTimeout: 1)
		unwiredService.refresh()
		Thread.sleep(forTimeInterval: 0.3)
		assert(unwiredStore.cached == heldByCache, "case 15: no sources configured must leave the cached verdict untouched, got \(String(describing: unwiredStore.cached))")
		assert(unwiredStore.writes == 0, "case 15: silence is not an answer — expected 0 writes, got \(unwiredStore.writes)")
		assert(unwiredStore.notified == 0, "case 15: expected 0 notifications, got \(unwiredStore.notified)")
		assert(unwiredService.isPremium == true, "case 15: premium must survive a refresh nobody could answer, got \(unwiredService.isPremium)")

		// 16. PM-02 row 1: the deadline is `sourceTimeout`, not a number of its own. Case 4 proves a
		//     stuck source cannot hold the verdict; this one ties the elapsed time to the configured
		//     value in both directions — the verdict cannot arrive BEFORE the deadline (both sources
		//     are awaited together) and must arrive well within a small multiple of it.
		let deadline: TimeInterval = 0.2
		let deadlineStore = SpyStore()
		let neverAdapty = FakeAdapty(answer: profile(active: false), delay: 30)
		let deadlineService = PremiumService(store: deadlineStore, adapty: neverAdapty, apple: FakeApple(receipt: ReceiptAnswer(isActive: true, expiresAt: nil)), levels: ["premium"], sourceTimeout: deadline)
		let deadlineStarted = Date()
		deadlineService.refresh()
		assert(wait(2) { deadlineStore.writes > 0 }, "case 16: a source that never answers must not hold the verdict past sourceTimeout \(deadline)s")
		let deadlineElapsed = Date().timeIntervalSince(deadlineStarted)
		assert(deadlineElapsed >= deadline, "case 16: the verdict cannot precede sourceTimeout \(deadline)s — both sources are awaited, took \(deadlineElapsed)s")
		assert(deadlineElapsed < deadline * 3, "case 16: the verdict must arrive under \(deadline * 3)s (3 x sourceTimeout \(deadline)s), took \(deadlineElapsed)s")
		assert(deadlineStore.cached?.source == .apple, "case 16: the verdict is built from the source that answered, got \(String(describing: deadlineStore.cached?.source))")

		// 17. PM-02 rows 3 and 6 (one mechanism, one case): there is no dedup logic, on purpose. What
		//     keeps a redundant refresh from writing and notifying is the equality guard on the store
		//     write plus the change guard in the flag setter — so two concurrent refreshes resolving to
		//     the same state cost exactly one write and one notification, and a third identical one
		//     costs exactly nothing.
		let dedupStore = SpyStore()
		let dedupExpiry = now + hour
		let dedupAdapty = FakeAdapty(answer: profile(active: true, expiresAt: dedupExpiry))
		let dedupService = PremiumService(store: dedupStore, adapty: dedupAdapty, apple: nil, levels: ["premium"], sourceTimeout: 1)
		dedupService.refresh()
		dedupService.refresh()
		assert(wait { dedupStore.writes > 0 }, "case 17: two refreshes must produce a verdict")
		Thread.sleep(forTimeInterval: 0.3)
		assert(dedupStore.writes == 1, "case 17: two concurrent refreshes onto the same state — exactly 1 write, got \(dedupStore.writes)")
		assert(dedupStore.notified == 1, "case 17: two concurrent refreshes onto the same state — exactly 1 notification, got \(dedupStore.notified)")
		dedupService.refresh()
		Thread.sleep(forTimeInterval: 0.3)
		assert(dedupStore.writes == 1, "case 17: a third identical refresh must add 0 writes — still exactly 1, got \(dedupStore.writes)")
		assert(dedupStore.notified == 1, "case 17: a third identical refresh must add 0 notifications — still exactly 1, got \(dedupStore.notified)")

		// 18. PM-02 row 4: an answer that arrives after the barrier already took the verdict is
		//     dropped, not applied on top of a fresher one. `withSingleResume` is the mechanism —
		//     exercised directly, because a second `resume` on a continuation is a hard crash, so
		//     "dropped silently" is exactly what has to be proven.
		var doubleValue: Int?
		Task {
			let settled: Int = await withSingleResume { resume in
				resume(1)
				resume(2)
			}
			doubleValue = settled
		}
		assert(wait { doubleValue != nil }, "case 18: withSingleResume must deliver the first value")
		assert(doubleValue == 1, "case 18: the first resume wins, expected exactly 1, got \(String(describing: doubleValue))")
		var lateResume: ((Int) -> Void)?
		var lateValue: Int?
		Task {
			let settled: Int = await withSingleResume { resume in
				lateResume = resume
				resume(10)
			}
			lateValue = settled
		}
		assert(wait { lateValue != nil }, "case 18: withSingleResume must deliver the first value")
		// The slow source finally answering, long after the deadline took the verdict.
		lateResume?(20)
		Thread.sleep(forTimeInterval: 0.2)
		assert(lateValue == 10, "case 18: a late resume must be dropped, expected the value to stay exactly 10, got \(String(describing: lateValue))")

		// 19. PM-03 row 7, through the facade (the risk row's own "how to reproduce" asks for the
		//     facade, not the pure resolver): a purchase has just gone through, but the cache holds a
		//     verified `inactive` Adapty gave us before it. Resolver step 2 would hand that straight
		//     back — the demotion inside `PremiumResolver.resolve` is what stops it.
		let staleVerifiedDenial = PremiumState(isPremium: false, source: .adapty, isVerified: true)
		let freshBuyStore = SpyStore(cached: staleVerifiedDenial)
		let freshBuyAdapty = FakeAdapty(answer: nil)
		freshBuyAdapty.buyResult = .success
		let freshBuyService = PremiumService(store: freshBuyStore, adapty: freshBuyAdapty, apple: FakeApple(receipt: nil), levels: ["premium"], sourceTimeout: 1)
		var freshBuyOutcome: PurchaseOutcome?
		freshBuyService.purchase("year.sub", placement: "main") { freshBuyOutcome = $0 }
		assert(wait { freshBuyOutcome != nil }, "case 19: purchase must call back")
		assert(freshBuyOutcome == .purchased, "case 19: the Adapty answer is passed through, expected .purchased, got \(String(describing: freshBuyOutcome))")
		let freshBuyCached = freshBuyStore.cached
		assert(
			freshBuyCached?.isPremium == true && freshBuyCached?.source == .apple && freshBuyCached?.isVerified == false && freshBuyCached?.expiresAt == nil && freshBuyCached?.localPurchase == true,
			"case 19: a stale verified denial must not swallow a fresh purchase, expected unverified premium from .apple, got \(String(describing: freshBuyCached))"
		)
		// The mark is stamped when it is set — PM-03 gives it a birth date so the window it opens
		// cannot stay open forever. It is checked for being present and young rather than compared to
		// a literal, because the resolver reads its own clock.
		assert(
			freshBuyCached?.localPurchaseAt.map { abs($0.timeIntervalSinceNow) < 5 } == true,
			"case 19: a fresh mark must carry its birth date, got \(String(describing: freshBuyCached?.localPurchaseAt))"
		)
		assert(freshBuyStore.writes == 1, "case 19: exactly 1 write, got \(freshBuyStore.writes)")
		assert(freshBuyStore.notified == 1, "case 19: exactly 1 .premiumDidChange, got \(freshBuyStore.notified)")

		// 20. PM-04 row 1: the user changed their mind. That is its own outcome and must never be
		//     folded in with real failures, or the app shows an error for a deliberate dismissal.
		let cancelStore = SpyStore(cached: .free)
		let cancelAdapty = FakeAdapty(answer: nil)
		cancelAdapty.buyResult = .cancelled
		let cancelService = PremiumService(store: cancelStore, adapty: cancelAdapty, apple: FakeApple(receipt: nil), levels: ["premium"], sourceTimeout: 1)
		var cancelOutcome: PurchaseOutcome?
		cancelService.purchase("year.sub", placement: "main") { cancelOutcome = $0 }
		assert(wait { cancelOutcome != nil }, "case 20: purchase must call back")
		assert(cancelOutcome == .cancelled, "case 20: a cancelled purchase maps to exactly .cancelled, never .failed, got \(String(describing: cancelOutcome))")
		assert(cancelService.isPremium == false, "case 20: a cancelled purchase must not grant premium, got \(cancelService.isPremium)")
		assert(cancelStore.writes == 0, "case 20: nothing changed — expected 0 writes, got \(cancelStore.writes)")

		// 21. PM-04 row 2: Adapty asked for the StoreKit fallback and there is no Apple side wired up
		//     at all (the product is not in the ids handed to `configure`, or StoreKit was never set
		//     up). The optional chain must settle to a plain failure — not a crash, not a hang.
		let noFallbackStore = SpyStore(cached: .free)
		let noFallbackAdapty = FakeAdapty(answer: nil)
		noFallbackAdapty.buyResult = .retryWithStoreKit
		let noFallbackService = PremiumService(store: noFallbackStore, adapty: noFallbackAdapty, apple: nil, levels: ["premium"], sourceTimeout: 1)
		var noFallbackOutcome: PurchaseOutcome?
		noFallbackService.purchase("year.sub", placement: "main") { noFallbackOutcome = $0 }
		assert(wait { noFallbackOutcome != nil }, "case 21: purchase must call back")
		assert(noFallbackOutcome == .failed, "case 21: no Apple side to fall back to gives exactly .failed, got \(String(describing: noFallbackOutcome))")
		assert(noFallbackService.isPremium == false, "case 21: a fallback that could not run must not grant premium, got \(noFallbackService.isPremium)")
		assert(noFallbackStore.writes == 0, "case 21: nothing changed — expected 0 writes, got \(noFallbackStore.writes)")

		// 22. PM-04 row 6: Adapty was never activated, so there is nothing to buy through. The failure
		//     is immediate and on the main queue — no network attempt, and no waiting out a timeout.
		let noAdaptyStore = SpyStore(cached: .free)
		let noAdaptyService = PremiumService(store: noAdaptyStore, adapty: nil, apple: FakeApple(receipt: nil), levels: ["premium"], sourceTimeout: 1)
		var noAdaptyOutcome: PurchaseOutcome?
		let noAdaptyStarted = Date()
		noAdaptyService.purchase("year.sub", placement: "main") { noAdaptyOutcome = $0 }
		assert(wait(0.3) { noAdaptyOutcome != nil }, "case 22: purchase must call back")
		let noAdaptyElapsed = Date().timeIntervalSince(noAdaptyStarted)
		assert(noAdaptyOutcome == .failed, "case 22: no Adapty means exactly .failed, got \(String(describing: noAdaptyOutcome))")
		assert(noAdaptyElapsed < 0.3, "case 22: the failure must not wait out sourceTimeout 1.0s, expected under 0.3s, took \(noAdaptyElapsed)s")
		assert(noAdaptyStore.writes == 0, "case 22: nothing changed — expected 0 writes, got \(noAdaptyStore.writes)")

		// 23. PM-06 row 2: the race is decided by which QUESTION is fresher, not by which answer was
		//     written last. Every question takes a generation number on its way out and the push takes
		//     one on arrival — that is when its answer was made — and an answer whose number is older
		//     than the one already applied is dropped whole, write and notification included.
		//
		//     Rewritten 2026-09-11: the user cancelled his own 2026-09-08 "leave it, the lock buys
		//     atomicity and the window is milliseconds". What changed it was what the race turned into
		//     once Adapty stopped revoking: the two answers now differ only by their expiry, so
		//     `isPremium` never flips, nothing notifies, and a renewal rolled back by a slower refresh
		//     is something the app is never told about at all.
		let raceStore = SpyStore()
		let raceAdapty = FakeAdapty(answer: profile(active: true, expiresAt: now + hour))
		let raceService = PremiumService(store: raceStore, adapty: raceAdapty, apple: nil, levels: ["premium"], sourceTimeout: 1)
		raceService.start()
		assert(wait { raceStore.cached?.source == .adapty }, "case 23: start() must settle on Adapty's answer first")
		assert(raceStore.writes == 2, "case 23: seed then start's refresh — exactly 2 writes before the race, got \(raceStore.writes)")
		// The stale reader: it reads the SAME profile, it just takes 0.3s to come back.
		raceAdapty.delay = 0.3
		raceService.refresh()
		// Not a sleep: the refresh has to be proven to have taken its number BEFORE the push takes
		// one, or the case would be running the opposite order and failing for the wrong reason.
		assert(wait { raceAdapty.asks == 2 }, "case 23: the slow refresh must be in flight before the push, got \(raceAdapty.asks) asks")
		// The fresher truth — a renewal pushing the expiry out — arriving while that refresh is still
		// waiting on its source.
		raceAdapty.premiumObserver?(profile(active: true, expiresAt: now + 2 * hour), true)
		assert(raceStore.cached?.expiresAt == now + 2 * hour, "case 23: the push must land, expected the renewed expiry right after it, got \(String(describing: raceStore.cached?.expiresAt))")
		assert(raceStore.writes == 3, "case 23: the push must write — expected exactly 3 writes, got \(raceStore.writes)")
		// Now let the older refresh finish and land on nothing.
		Thread.sleep(forTimeInterval: 0.4)
		assert(
			raceStore.cached == PremiumState(isPremium: true, source: .adapty, isVerified: true, expiresAt: now + 2 * hour),
			"case 23: the older refresh must be dropped whole — expected the push's renewed expiry to stand, got \(String(describing: raceStore.cached))"
		)
		assert(raceStore.writes == 3, "case 23: a dropped answer writes nothing — still exactly 3 writes, got \(raceStore.writes)")
		assert(raceStore.notified == 1, "case 23: premium itself never flipped — 1 notification from the initial grant, got \(raceStore.notified)")

		// 23b. PM-06 row 2, the exception without which the counter does harm: an answer carrying a
		//      local purchase is never dropped as stale. Money that just cleared is newer than any
		//      source answer, and the mark it brings is the only thing holding access open until
		//      Adapty has seen the payment. Here the purchase's barrier goes out first and comes back
		//      last, overtaken by an ordinary dashboard grant — under the plain rule it would be
		//      discarded, and the user who just paid would be left with someone else's verdict.
		let markStore = SpyStore()
		let markAdapty = FakeAdapty(answer: profile(active: false))
		let markService = PremiumService(store: markStore, adapty: markAdapty, apple: nil, levels: ["premium"], sourceTimeout: 1)
		markService.start()
		assert(wait { markAdapty.asks == 1 }, "case 23b: start() must ask once")
		assert(wait { markStore.writes == 1 }, "case 23b: a denied start writes only the seed, got \(markStore.writes)")
		markAdapty.delay = 0.3
		markService.purchaseDelivered()
		assert(wait { markAdapty.asks == 2 }, "case 23b: the purchase's barrier must be in flight before the push, got \(markAdapty.asks) asks")
		markAdapty.premiumObserver?(profile(active: true, expiresAt: now + hour), true)
		assert(markStore.cached?.localPurchase == false, "case 23b: the overtaking grant carries no mark, got \(String(describing: markStore.cached))")
		assert(markStore.writes == 2, "case 23b: the grant must write, expected exactly 2 writes, got \(markStore.writes)")
		assert(wait { markStore.cached?.localPurchase == true }, "case 23b: a local purchase must never be dropped as stale — the user paid and would be left without the mark, got \(String(describing: markStore.cached))")
		assert(markStore.cached?.isPremium == true, "case 23b: and access stays open, got \(String(describing: markStore.cached))")
		assert(markStore.notified == 1, "case 23b: premium went on once and stayed on — exactly 1 notification, got \(markStore.notified)")

		// 24. PM-06 row 3: Adapty re-pushing a profile it already pushed is free. The second delivery
		//     of the identical profile must cost exactly zero writes and zero notifications.
		let idempotentStore = SpyStore()
		let idempotentAdapty = FakeAdapty(answer: nil)
		let idempotentService = PremiumService(store: idempotentStore, adapty: idempotentAdapty, apple: nil, levels: ["premium"], sourceTimeout: 1)
		idempotentService.start()
		Thread.sleep(forTimeInterval: 0.3)
		assert(idempotentStore.writes == 1, "case 24: a silent start writes only the seed, expected exactly 1, got \(idempotentStore.writes)")
		let repeatedProfile = profile(active: true, expiresAt: now + hour)
		idempotentAdapty.premiumObserver?(repeatedProfile, true)
		assert(idempotentStore.writes == 2, "case 24: the first push must write, expected exactly 2 writes total, got \(idempotentStore.writes)")
		assert(idempotentStore.notified == 1, "case 24: the first push must notify, expected exactly 1, got \(idempotentStore.notified)")
		idempotentAdapty.premiumObserver?(repeatedProfile, true)
		assert(idempotentStore.writes == 2, "case 24: an identical push must add 0 writes — still exactly 2, got \(idempotentStore.writes)")
		assert(idempotentStore.notified == 1, "case 24: an identical push must add 0 notifications — still exactly 1, got \(idempotentStore.notified)")

		// 25. PM-06 row 4: premium granted by hand from the Adapty dashboard. It reaches the app as an
		//     ordinary profile push and needs no request from the app at all — `FakeAdapty`'s observer
		//     stands in for the real `didLoadLatestProfile` delegate callback, which only the live SDK
		//     can fire. The grant must land as fully verified Adapty premium.
		let grantStore = SpyStore()
		let grantAdapty = FakeAdapty(answer: nil)
		let grantService = PremiumService(store: grantStore, adapty: grantAdapty, apple: nil, levels: ["premium"], sourceTimeout: 1)
		grantService.start()
		Thread.sleep(forTimeInterval: 0.3)
		assert(grantService.isPremium == false, "case 25: nothing has granted premium yet, got \(grantService.isPremium)")
		let grantedUntil = now + hour
		grantAdapty.premiumObserver?(profile(active: true, expiresAt: grantedUntil), true)
		assert(
			grantStore.cached == PremiumState(isPremium: true, source: .adapty, isVerified: true, expiresAt: grantedUntil),
			"case 25: a dashboard grant must land as verified Adapty premium with the profile's expiry, got \(String(describing: grantStore.cached))"
		)
		assert(grantService.isPremium == true, "case 25: the grant must reach premium access, got \(grantService.isPremium)")
		assert(grantStore.premium == true, "case 25: the flag mirror must move with it, got \(grantStore.premium)")
		assert(grantStore.notified == 1, "case 25: exactly 1 .premiumDidChange, got \(grantStore.notified)")

		// 26. PM-04 row 15 (rewritten for 0.3.0; row 11 is what it replaces). Adapty answered with an
		//     error, and the facade must read that as "not paid" — no premium, no local-purchase mark.
		//
		//     Row 11 read the same error the opposite way: on 2.10.x `makePurchase` answered
		//     `Result<Void, AdaptyError>`, so a purchase that completed and one that never started were
		//     told apart only by an error code, and codes 2004/2005 were taken to mean "Apple charged,
		//     Adapty could not confirm" — `.pending` WITH access. On 4.1.3 a completed purchase comes
		//     back as `AdaptyPurchaseResult.success`, so an error means the opposite of what it used to
		//     (AD-04 row 9): the verdict `paidUnconfirmed` is gone and this branch grants nothing.
		//
		//     What survives from row 11 is the half that was never about the verdict: a failure still
		//     must NOT run the StoreKit fallback. Only `retryWithStoreKit` does.
		let paidStore = SpyStore(cached: .free)
		let paidAdapty = FakeAdapty(answer: nil)
		paidAdapty.buyResult = .failed
		let paidApple = FakeApple(receipt: nil)
		let paidService = PremiumService(store: paidStore, adapty: paidAdapty, apple: paidApple, levels: ["premium"], sourceTimeout: 1)
		var paidOutcome: PurchaseOutcome?
		paidService.purchase("year.sub", placement: "main") { paidOutcome = $0 }
		assert(wait { paidOutcome != nil }, "case 26: purchase must call back")
		assert(paidOutcome == .failed, "case 26: an error from Adapty is a purchase that did not happen — exactly .failed, got \(String(describing: paidOutcome))")
		assert(paidApple.purchasedProductId == nil, "case 26: a failed purchase must not fall back to StoreKit — only .retryWithStoreKit does; it was asked to buy \(String(describing: paidApple.purchasedProductId))")
		assert(paidService.isPremium == false, "case 26: nothing was paid — premium must stay off, got \(paidService.isPremium)")
		assert(paidStore.cached?.localPurchase == false, "case 26: no payment, no local-purchase mark, got \(String(describing: paidStore.cached))")
		assert(paidStore.writes == 0, "case 26: nothing changed — expected 0 writes, got \(paidStore.writes)")

		// 27. PM-04 row 12: Ask to Buy waiting for a parent, or an SDK call that never came back. Neither
		//     bought nor refused — no access, no error, and no fallback: buying through StoreKit would
		//     bypass the approval the purchase is waiting for.
		let pendingStore = SpyStore(cached: .free)
		let pendingAdapty = FakeAdapty(answer: nil)
		pendingAdapty.buyResult = .pending
		let pendingApple = FakeApple(receipt: nil)
		let pendingService = PremiumService(store: pendingStore, adapty: pendingAdapty, apple: pendingApple, levels: ["premium"], sourceTimeout: 1)
		var pendingOutcome: PurchaseOutcome?
		pendingService.purchase("year.sub", placement: "main") { pendingOutcome = $0 }
		assert(wait { pendingOutcome != nil }, "case 27: purchase must call back")
		assert(pendingOutcome == .pending, "case 27: an undecided purchase maps to exactly .pending, got \(String(describing: pendingOutcome))")
		assert(pendingApple.purchasedProductId == nil, "case 27: an undecided purchase must not fall back to StoreKit, it was asked to buy \(String(describing: pendingApple.purchasedProductId))")
		assert(pendingService.isPremium == false, "case 27: nothing was paid — premium must stay off, got \(pendingService.isPremium)")
		assert(pendingStore.cached?.localPurchase == false, "case 27: no payment, no mark, got \(String(describing: pendingStore.cached))")
		assert(pendingStore.writes == 0, "case 27: nothing changed — expected 0 writes, got \(pendingStore.writes)")

		// 28. PM-04 row 13: permanently unavailable — parental controls, a product missing from this
		//     storefront, a promotional offer the store refuses to sign. Its own outcome, not `.failed`,
		//     so the app can hide the button instead of offering a retry that fails identically. And no
		//     fallback: StoreKit would happily sell the same product at full price, without the offer.
		let unavailableStore = SpyStore(cached: .free)
		let unavailableAdapty = FakeAdapty(answer: nil)
		unavailableAdapty.buyResult = .unavailable
		let unavailableApple = FakeApple(receipt: nil)
		let unavailableService = PremiumService(store: unavailableStore, adapty: unavailableAdapty, apple: unavailableApple, levels: ["premium"], sourceTimeout: 1)
		var unavailableOutcome: PurchaseOutcome?
		unavailableService.purchase("year.sub", placement: "main") { unavailableOutcome = $0 }
		assert(wait { unavailableOutcome != nil }, "case 28: purchase must call back")
		assert(unavailableOutcome == .unavailable, "case 28: a permanently unavailable product maps to exactly .unavailable, never .failed, got \(String(describing: unavailableOutcome))")
		assert(unavailableApple.purchasedProductId == nil, "case 28: .unavailable must not fall back to StoreKit — a discounted offer would be bought at full price; it was asked to buy \(String(describing: unavailableApple.purchasedProductId))")
		assert(unavailableService.isPremium == false, "case 28: nothing was paid — premium must stay off, got \(unavailableService.isPremium)")
		assert(unavailableStore.writes == 0, "case 28: nothing changed — expected 0 writes, got \(unavailableStore.writes)")

		// 29. PM-01 row 6: publishing the cache is a full resolve with every source silent, not a
		//     verbatim write-back. A cached premium whose expiry has passed is closed right there, on a
		//     device that may never reach the network — otherwise an expired subscription would read as
		//     premium forever offline. The resolver's own arithmetic is pinned by
		//     `premium-resolver-check.sh` case 6; what this case adds is that `start()` actually routes
		//     the cache through it before anyone can read `isPremium`.
		let lapsedStore = SpyStore(cached: PremiumState(isPremium: true, source: .adapty, isVerified: true, expiresAt: now - hour), premium: true)
		let lapsedService = PremiumService(store: lapsedStore, adapty: nil, apple: nil, levels: ["premium"], sourceTimeout: 1)
		lapsedService.start()
		assert(lapsedService.isPremium == false, "case 29: an expired cached premium must be closed by start() itself, before any network answer, got \(lapsedService.isPremium)")
		// Spelled out: `?.source == .none` binds to `Optional.none` and silently asserts "the cache is nil".
		assert(lapsedStore.cached?.source == PremiumSource.none, "case 29: nobody granted it — expected source .none, got \(String(describing: lapsedStore.cached?.source))")
		assert(lapsedStore.cached?.expiresAt == now - hour, "case 29: the expiry is carried through so the app can still see it, expected \(now - hour), got \(String(describing: lapsedStore.cached?.expiresAt))")
		assert(lapsedStore.premium == false, "case 29: the flag mirror must move with it, got \(lapsedStore.premium)")
		assert(lapsedStore.notified == 1, "case 29: the flag went true-false — exactly 1 .premiumDidChange, got \(lapsedStore.notified)")
		// start()'s own refresh resolves the same verdict from the state just written, so it adds nothing.
		Thread.sleep(forTimeInterval: 0.3)
		assert(lapsedStore.writes == 1, "case 29: publish writes once and the refresh behind it changes nothing — expected exactly 1 write, got \(lapsedStore.writes)")

		// 30. PM-06 row 5 (AD-05 row 2 through the facade): the first push of a process is the profile
		//     the SDK had on disk from the last launch, handed to the delegate before any request goes
		//     out. A "no premium" from there must not close access, or a paying user on a slow network
		//     sees the paywall on every cold start. Since 2026-09-11 no push saying "no premium" closes
		//     access, verified or not, so the denial half is pinned as an identity. The wiring — that
		//     the observer forwards provenance at all, through the real
		//     `PremiumAccess(profile:levels:isVerified:)` conversion — is pinned below it, on a grant,
		//     which is the only answer whose provenance still reaches the verdict.
		let provenanceStore = SpyStore(cached: PremiumState(isPremium: true, source: .adapty, isVerified: true, expiresAt: now + hour), premium: true)
		let provenanceAdapty = FakeAdapty(answer: nil)
		let provenanceService = PremiumService(store: provenanceStore, adapty: provenanceAdapty, apple: nil, levels: ["premium"], sourceTimeout: 1)
		provenanceService.start()
		Thread.sleep(forTimeInterval: 0.3)
		assert(provenanceStore.writes == 0, "case 30: a live cache and a silent source change nothing — expected 0 writes after start(), got \(provenanceStore.writes)")
		provenanceAdapty.premiumObserver?(profile(active: false), false)
		assert(provenanceService.isPremium == true, "case 30: an unverified push saying inactive must not close access, got \(provenanceService.isPremium)")
		// The very same profile, this time from the network. It must change nothing either.
		provenanceAdapty.premiumObserver?(profile(active: false), true)
		assert(provenanceService.isPremium == true, "case 30: a verified push saying inactive must not close access either, got \(provenanceService.isPremium)")
		assert(provenanceStore.writes == 0, "case 30: both denials resolve back to the same cached verdict — expected still 0 writes, got \(provenanceStore.writes)")
		assert(provenanceStore.notified == 0, "case 30: nothing changed — expected 0 notifications, got \(provenanceStore.notified)")
		// The wiring itself, read where provenance still decides something: a grant carries its own.
		provenanceAdapty.premiumObserver?(profile(active: true, expiresAt: now + 2 * hour), false)
		assert(provenanceStore.cached == PremiumState(isPremium: true, source: .adapty, isVerified: false, expiresAt: now + 2 * hour), "case 30: a grant pushed from the SDK's own storage must arrive unverified, got \(String(describing: provenanceStore.cached))")
		provenanceAdapty.premiumObserver?(profile(active: true, expiresAt: now + 2 * hour), true)
		assert(provenanceStore.cached?.isVerified == true, "case 30: the same grant from the network must arrive verified, got \(String(describing: provenanceStore.cached?.isVerified))")
		assert(provenanceStore.writes == 2, "case 30: only the two grants moved the state — expected 2 writes, got \(provenanceStore.writes)")
		assert(provenanceStore.notified == 0, "case 30: premium stayed true the whole way — expected 0 .premiumDidChange, got \(provenanceStore.notified)")

		// 31. PM-07 row 11 (AD-02 row 5 through the facade): `hasPaywall` answers `false` both while a
		//     placement is still loading and when nothing is ever coming, and a screen cannot choose
		//     between a spinner and an empty state out of one boolean. `paywallState` is the answer, and
		//     the facade has to hand Adapty's own verdict over untouched. `AdaptyServiceCheck` T10/T10b
		//     pin the three values where they are decided; what is pinned here is that the facade neither
		//     flattens them nor synthesizes them out of `hasPaywall` — the fake keeps `hasPaywall` at
		//     `false` throughout, so a facade deriving one from the other could never report `.ready`.
		let stateAdapty = StatefulPaywallAdapty()
		let stateService = PremiumService(store: SpyStore(), adapty: stateAdapty, apple: nil, levels: ["premium"], sourceTimeout: 1)
		stateAdapty.paywallStateAnswer = .loading
		assert(stateService.paywallState(placement: "main") == .loading, "case 31: an attempt still in flight must reach the app as .loading, got \(stateService.paywallState(placement: "main"))")
		assert(stateService.hasPaywall(placement: "main") == false, "case 31: hasPaywall stays false while loading — the two answers are independent, got \(stateService.hasPaywall(placement: "main"))")
		stateAdapty.paywallStateAnswer = .unavailable
		assert(stateService.paywallState(placement: "main") == .unavailable, "case 31: a placement that is never coming must reach the app as .unavailable, got \(stateService.paywallState(placement: "main"))")
		stateAdapty.paywallStateAnswer = .ready
		assert(stateService.paywallState(placement: "main") == .ready, "case 31: a loaded paywall must reach the app as .ready, got \(stateService.paywallState(placement: "main"))")
		// No Adapty wired at all: nothing is in flight and nothing will arrive. `.unavailable`, never
		// `.loading`, or a screen spins forever waiting on a source the package does not have.
		let noSourceService = PremiumService(store: SpyStore(), adapty: nil, apple: nil, levels: ["premium"], sourceTimeout: 1)
		assert(noSourceService.paywallState(placement: "main") == .unavailable, "case 31: with no Adapty source the state must be .unavailable, never .loading, got \(noSourceService.paywallState(placement: "main"))")

		// 32. PM-07 row 12: the Adapty layer never came up — an empty key, or an obfuscated one that
		//     decrypted into something that is not a key — and it never will for the rest of the run.
		//     Its `products` answer is `.notReady`, character for character the answer a live layer
		//     gives while its paywall is still on the way, so the price fallback of row 9 fires and
		//     draws a paywall out of the store's REAL prices. Every button on it then answers
		//     `.failed`, because `AdaptyService.buyProduct` refuses on the same flag the layer is
		//     down by. Nothing to sell means nothing to show.
		let catalogue: [String: PremiumProduct] = [
			"year.sub": PremiumProduct(id: "year.sub", localizedTitle: "Year", localizedPrice: "$29.99", price: 29.99, currencyCode: "USD", subscriptionPeriod: PremiumPeriod(unit: .year, numberOfUnits: 1), introductoryOffer: nil),
			"week.sub": PremiumProduct(id: "week.sub", localizedTitle: "Week", localizedPrice: "$4.99", price: 4.99, currencyCode: "USD", subscriptionPeriod: PremiumPeriod(unit: .week, numberOfUnits: 1), introductoryOffer: nil),
		]
		let deadLayerApple = FakeApple(receipt: nil)
		deadLayerApple.catalogue = catalogue
		let deadLayerService = PremiumService(store: SpyStore(), adapty: InactiveLayerAdapty(), apple: deadLayerApple, levels: ["premium"], sourceTimeout: 1, productIds: ["year.sub", "week.sub"])
		var deadLayerProducts: [PremiumProduct]?
		deadLayerService.products(placement: "main") { deadLayerProducts = $0 }
		assert(wait { deadLayerProducts != nil }, "case 32: products must call back")
		assert(
			deadLayerProducts?.isEmpty == true,
			"case 32: a layer that never came up must not price the configured ids from the store — every button on that paywall would fail; expected 0 products, got \(deadLayerProducts?.map(\.id).sorted() ?? [])"
		)
		// The other half, and the case is worthless without it: the identical store, the identical
		// ids, and a layer that IS up whose paywall simply has not arrived. Row 9's fallback must
		// still run there, or the fix above would have closed the paywall for everybody.
		let liveLayerApple = FakeApple(receipt: nil)
		liveLayerApple.catalogue = catalogue
		let liveLayerService = PremiumService(store: SpyStore(), adapty: FakeAdapty(answer: nil), apple: liveLayerApple, levels: ["premium"], sourceTimeout: 1, productIds: ["year.sub", "week.sub"])
		var liveLayerProducts: [PremiumProduct]?
		liveLayerService.products(placement: "main") { liveLayerProducts = $0 }
		assert(wait { liveLayerProducts != nil }, "case 32: products must call back")
		assert(
			liveLayerProducts?.map(\.id).sorted() == ["week.sub", "year.sub"],
			"case 32: a live layer whose paywall has not arrived must still fall back to the configured ids (PM-07 row 9), expected both, got \(liveLayerProducts?.map(\.id).sorted() ?? [])"
		)

		// 33. PM-04 row 14: the placement the money came from. The app used to write `purchasePlace`
		//     itself after every purchase, which made every migration one more chance to forget it —
		//     and a forgotten attribute reads on the dashboard like a paywall that stopped selling.
		//     The placement is already in the call, so the package writes it. Condition: `didPay`,
		//     the same flag the local-purchase mark hangs on — one condition, not two that drift.
		fakeAdaptyProfileWrites = []
		let placeAdapty = FakeAdapty(answer: nil)
		placeAdapty.buyResult = .success
		let placeService = PremiumService(store: SpyStore(cached: .free), adapty: placeAdapty, apple: FakeApple(receipt: nil), levels: ["premium"], sourceTimeout: 1)
		var placeOutcome: PurchaseOutcome?
		placeService.purchase("year.sub", placement: "main") { placeOutcome = $0 }
		assert(wait { placeOutcome != nil }, "case 33: purchase must call back")
		assert(
			fakeAdaptyProfileWrites == ["purchasePlace=main"],
			"case 33: a paid purchase must write the placement it was paid from — expected [\"purchasePlace=main\"], got \(fakeAdaptyProfileWrites)"
		)

		// The fallback pays for the same placement by the other road. Money is money: which side of
		// the facade took it is not something the dashboard can see or should care about.
		fakeAdaptyProfileWrites = []
		let placeFallbackAdapty = FakeAdapty(answer: nil)
		placeFallbackAdapty.buyResult = .retryWithStoreKit
		let placeFallbackApple = FakeApple(receipt: nil)
		placeFallbackApple.purchaseResult = .purchased
		let placeFallbackService = PremiumService(store: SpyStore(cached: .free), adapty: placeFallbackAdapty, apple: placeFallbackApple, levels: ["premium"], sourceTimeout: 1)
		var placeFallbackOutcome: PurchaseOutcome?
		placeFallbackService.purchase("year.sub", placement: "onboarding") { placeFallbackOutcome = $0 }
		assert(wait { placeFallbackOutcome != nil }, "case 33: the fallback purchase must call back")
		assert(
			fakeAdaptyProfileWrites == ["purchasePlace=onboarding"],
			"case 33: a StoreKit-fallback purchase must write the placement too — expected [\"purchasePlace=onboarding\"], got \(fakeAdaptyProfileWrites)"
		)

		// And the half the other two are worthless without: nobody paid, so nothing is written. A
		// write that always runs would stamp the profile with a placement the user never paid from —
		// worse than a missing attribute, because it reads as true.
		fakeAdaptyProfileWrites = []
		let placeCancelAdapty = FakeAdapty(answer: nil)
		placeCancelAdapty.buyResult = .cancelled
		let placeCancelService = PremiumService(store: SpyStore(cached: .free), adapty: placeCancelAdapty, apple: FakeApple(receipt: nil), levels: ["premium"], sourceTimeout: 1)
		var placeCancelOutcome: PurchaseOutcome?
		placeCancelService.purchase("year.sub", placement: "main") { placeCancelOutcome = $0 }
		assert(wait { placeCancelOutcome != nil }, "case 33: the cancelled purchase must call back")
		assert(
			fakeAdaptyProfileWrites.isEmpty,
			"case 33: a purchase nobody paid for must write no placement — got \(fakeAdaptyProfileWrites)"
		)

		// 34. PM-02 row 7: a barrier where nobody answered leaves the verdict resting on the last
		//     launch's memory and re-asks nobody — a cold start with no network would cost a whole
		//     session. Coming back to the foreground re-asks it, for as long as the question is open
		//     and not one call after it closes. The store cannot show any of this: a barrier that
		//     resolves to the state already cached writes nothing, so what is counted is the question.
		let openAdapty = CountingAdapty(answer: nil)
		let openService = PremiumService(store: SpyStore(cached: .free), adapty: openAdapty, apple: FakeApple(receipt: nil), levels: ["premium"], sourceTimeout: 1)
		openService.start()
		assert(wait { openAdapty.asks == 1 }, "case 34: start() must ask once, got \(openAdapty.asks)")
		openService.refreshIfUnanswered()
		assert(wait { openAdapty.asks == 2 }, "case 34: nobody answered the first barrier — coming back to the foreground must ask again, got \(openAdapty.asks)")
		// Adapty finally answers, verified. From here the profile push keeps the verdict fresh, and
		// re-asking on every foreground would buy nothing.
		openAdapty.answer = profile(active: true, expiresAt: now + hour)
		openService.refreshIfUnanswered()
		assert(wait { openService.isPremium }, "case 34: the answer must land as premium")
		assert(openAdapty.asks == 3, "case 34: exactly 3 asks — that third one is the one that got the answer, got \(openAdapty.asks)")
		openService.refreshIfUnanswered()
		Thread.sleep(forTimeInterval: 0.2)
		assert(openAdapty.asks == 3, "case 34: the question is closed — a later foreground must ask nothing, still exactly 3, got \(openAdapty.asks)")
		// Only the foreground retry is gated by the flag. The app's own `refresh()` never is.
		openService.refresh()
		assert(wait { openAdapty.asks == 4 }, "case 34: refresh() itself must still work after the question closed, got \(openAdapty.asks)")

		// 35. PM-02 row 8: the first push of a process is the profile the SDK had on disk, handed over
		//     before any request goes out (AD-05 row 2). Reading it as an answer would cancel the very
		//     retry row 7 exists for — on a device with no network that push is all that ever arrives.
		let pushAdapty = CountingAdapty(answer: nil)
		let pushService = PremiumService(store: SpyStore(cached: .free), adapty: pushAdapty, apple: FakeApple(receipt: nil), levels: ["premium"], sourceTimeout: 1)
		pushService.start()
		assert(wait { pushAdapty.asks == 1 }, "case 35: start() must ask once, got \(pushAdapty.asks)")
		pushAdapty.premiumObserver?(profile(active: true, expiresAt: now + hour), false)
		assert(pushService.isPremium == true, "case 35: an unverified push saying active still grants — doubt goes to the user, got \(pushService.isPremium)")
		pushService.refreshIfUnanswered()
		assert(wait { pushAdapty.asks == 2 }, "case 35: a profile off the SDK's own disk is not an answer — the question must stay open, got \(pushAdapty.asks)")
		// The same profile, this time from the network. That one is Adapty actually answering.
		pushAdapty.premiumObserver?(profile(active: true, expiresAt: now + hour), true)
		pushService.refreshIfUnanswered()
		Thread.sleep(forTimeInterval: 0.2)
		assert(pushAdapty.asks == 2, "case 35: a verified push closes the question — still exactly 2, got \(pushAdapty.asks)")

		// 36. PM-02 row 9: an app built without Adapty has nobody to wait for, so its question is
		//     closed before it is ever asked and a foreground costs it nothing. The second half is
		//     what makes the first meaningful: it is the flag that stops the retry, not a service
		//     that could not resolve — the same sources through `refresh()` grant premium at once.
		let noWaitStore = SpyStore(cached: .free)
		let noWaitService = PremiumService(store: noWaitStore, adapty: nil, apple: FakeApple(receipt: ReceiptAnswer(isActive: true, expiresAt: now + hour)), levels: ["premium"], sourceTimeout: 1)
		noWaitService.refreshIfUnanswered()
		Thread.sleep(forTimeInterval: 0.3)
		assert(noWaitStore.writes == 0, "case 36: with no Adapty there is nothing to re-ask — expected 0 writes, got \(noWaitStore.writes)")
		assert(noWaitService.isPremium == false, "case 36: and nothing was resolved, got \(noWaitService.isPremium)")
		noWaitService.refresh()
		assert(wait { noWaitService.isPremium }, "case 36: refresh() must still resolve the receipt — the flag stopped the foreground retry, not the service")
		assert(noWaitStore.writes == 1, "case 36: exactly 1 write, got \(noWaitStore.writes)")

		// 37. PM-02 rows 11 and 12: the deadline is chosen by the call site. `start()` has the splash
		//     behind it and gives up early; the app's own `refresh()` is in no hurry and waits the
		//     full one. The second half is what makes the first safe rather than a trade of accuracy
		//     for speed: the source that did not make it left the question open, so the foreground
		//     retry gets, patiently, the answer the impatient start missed.
		let hurryStore = SpyStore(cached: .free)
		let hurryAdapty = FakeAdapty(answer: profile(active: true, expiresAt: now + hour), delay: 0.5)
		let hurryService = PremiumService(store: hurryStore, adapty: hurryAdapty, apple: FakeApple(receipt: nil), levels: ["premium"], sourceTimeout: 1.5, waitingTimeout: 0.15)
		hurryService.start()
		Thread.sleep(forTimeInterval: 0.3)
		assert(hurryService.isPremium == false, "case 37: start() must not wait out a source slower than the impatient deadline, got \(hurryService.isPremium)")
		assert(hurryStore.writes == 0, "case 37: it resolved to the cached free verdict — expected 0 writes, got \(hurryStore.writes)")
		// Past the source's own delay: an answer that missed its deadline is dropped, not applied late.
		Thread.sleep(forTimeInterval: 0.4)
		assert(hurryService.isPremium == false, "case 37: an answer that missed the deadline must not land afterwards, got \(hurryService.isPremium)")
		// The same source, the same delay, the patient deadline — this one waits for it.
		let patientStarted = Date()
		hurryService.refreshIfUnanswered()
		assert(wait { hurryService.isPremium }, "case 37: the question stayed open, so the patient retry must get the answer the impatient start missed")
		let patientElapsed = Date().timeIntervalSince(patientStarted)
		assert(patientElapsed >= 0.5, "case 37: the patient deadline must actually wait out the 0.5s source, took \(patientElapsed)s")
		assert(hurryStore.cached?.source == .adapty, "case 37: and the verdict is Adapty's, got \(String(describing: hurryStore.cached?.source))")

		// 38. PM-02 rows 11 and 13: `restore` awaits the barrier before calling back, so the barrier's
		//     deadline IS the user's wait. A source slower than the impatient one must not hold the
		//     completion — and the verdict does not need it anyway: the restore's own mark decided.
		let restoreSlowAdapty = FakeAdapty(answer: profile(active: false), delay: 1.0)
		let restoreSlowApple = FakeApple(receipt: nil)
		restoreSlowApple.restoreResult = .restored
		let restoreSlowStore = SpyStore(cached: .free)
		let restoreSlowService = PremiumService(store: restoreSlowStore, adapty: restoreSlowAdapty, apple: restoreSlowApple, levels: ["premium"], sourceTimeout: 3, waitingTimeout: 0.2)
		var restoreSlowOutcome: RestoreOutcome?
		let restoreSlowStarted = Date()
		restoreSlowService.restore { restoreSlowOutcome = $0 }
		assert(wait { restoreSlowOutcome != nil }, "case 38: restore must call back")
		let restoreSlowElapsed = Date().timeIntervalSince(restoreSlowStarted)
		assert(restoreSlowElapsed < 0.6, "case 38: a source slower than the impatient deadline must not hold the completion, took \(restoreSlowElapsed)s")
		assert(restoreSlowOutcome == .restored, "case 38: the restore outcome is passed through, got \(String(describing: restoreSlowOutcome))")
		assert(restoreSlowService.isPremium == true, "case 38: the mark decides the verdict without waiting for Adapty, got \(restoreSlowService.isPremium)")

		// Row 13: an app that configured the patient deadline SHORTER than the impatient default.
		// The impatient one can never be the longer of the two, or both names are lying — it is
		// clamped, and this restore must still come back inside the 0.2s the app asked for.
		let clampApple = FakeApple(receipt: nil)
		clampApple.restoreResult = .restored
		let clampService = PremiumService(store: SpyStore(cached: .free), adapty: FakeAdapty(answer: profile(active: false), delay: 1.0), apple: clampApple, levels: ["premium"], sourceTimeout: 0.2, waitingTimeout: 2)
		var clampOutcome: RestoreOutcome?
		let clampStarted = Date()
		clampService.restore { clampOutcome = $0 }
		assert(wait { clampOutcome != nil }, "case 38: the restore must call back")
		let clampElapsed = Date().timeIntervalSince(clampStarted)
		assert(clampElapsed < 0.6, "case 38: the impatient deadline must be clamped to the patient one the app configured, took \(clampElapsed)s")

		// 39. PM-03 row 23, the half the resolver cannot see: whether the profile's date reaches the
		//     verdict at all. `PremiumResolverCheck` case 11 builds a `PremiumAccess` by hand, so it
		//     stays green even if the Adapty mapping keeps throwing the date away — which is exactly
		//     what it did until 2026-09-11. Only a real profile, through the real conversion, tells
		//     the two apart. The level here is inactive and dated in the past: a refunded subscription.
		let endedStore = SpyStore(cached: PremiumState(isPremium: true, source: .adapty, isVerified: true, expiresAt: now + 10 * hour), premium: true)
		let endedAdapty = FakeAdapty(answer: nil)
		let endedService = PremiumService(store: endedStore, adapty: endedAdapty, apple: nil, levels: ["premium"], sourceTimeout: 1)
		endedService.start()
		Thread.sleep(forTimeInterval: 0.3)
		assert(endedService.isPremium == true, "case 39: a live cache and a silent source must leave premium alone, got \(endedService.isPremium)")
		endedAdapty.premiumObserver?(profile(active: false, expiresAt: now - hour), true)
		assert(endedService.isPremium == false, "case 39: an ended level's own expiry must reach the verdict and close access, got \(endedService.isPremium)")
		assert(endedStore.cached?.expiresAt == now - hour, "case 39: the verdict must carry the profile's date, not the cache's, got \(String(describing: endedStore.cached?.expiresAt))")
		assert(endedStore.notified == 1, "case 39: premium actually flipped, so the app must hear about it exactly once, got \(endedStore.notified)")
		// The contrast, on the same fixture: the same inactive level dated ahead closes nothing. It is
		// what keeps the rule "Adapty never revokes" honest — the denial is not what did the closing
		// above, the date was.
		let aheadStore = SpyStore(cached: PremiumState(isPremium: true, source: .adapty, isVerified: true, expiresAt: now + 10 * hour), premium: true)
		let aheadAdapty = FakeAdapty(answer: nil)
		let aheadService = PremiumService(store: aheadStore, adapty: aheadAdapty, apple: nil, levels: ["premium"], sourceTimeout: 1)
		aheadService.start()
		Thread.sleep(forTimeInterval: 0.3)
		aheadAdapty.premiumObserver?(profile(active: false, expiresAt: now + hour), true)
		assert(aheadService.isPremium == true, "case 39: an inactive level dated ahead must not close access, got \(aheadService.isPremium)")
		assert(aheadStore.cached?.expiresAt == now + hour, "case 39: the profile's date replaces the cache's either way, got \(String(describing: aheadStore.cached?.expiresAt))")
		assert(aheadStore.notified == 0, "case 39: premium never moved, so nothing to announce, got \(aheadStore.notified)")

		// MARK: PM-09 — activeSubscriptionIds (0.10.0). Cases 41-53, one per row of the risk table, written
		// red first: the operation did not exist, so the file did not compile.

		let pm9Year = subscriptionJSON("year.sub", active: true)
		let pm9Week = subscriptionJSON("week.sub", active: true)

		// 41. PM-09 row 1 — an inactive layer is "I do not know" at once. The fake would answer, and slowly,
		//     if it were asked: the proof is that it was not asked and the screen did not wait for its deadline.
		let pm9InactiveAdapty = InactiveProbeAdapty(answer: decodedProfile(subscriptions: ["year.sub": pm9Year]), delay: 5)
		let pm9InactiveService = PremiumService(store: SpyStore(), adapty: pm9InactiveAdapty, apple: nil, levels: ["premium"], sourceTimeout: 5)
		let pm9Inactive = ActiveSubscriptionsProbe(asking: pm9InactiveService)
		wait(1) { !pm9Inactive.answers.isEmpty }
		assert(pm9Inactive.answers == [nil], "case 41 (PM-09 row 1): an inactive layer must answer nil, got \(pm9Inactive.answers)")
		assert((pm9Inactive.firstAnswerAfter ?? 99) < 0.5, "case 41 (PM-09 row 1): nil must come at once, not after the 2s screen deadline — took \(String(describing: pm9Inactive.firstAnswerAfter))s")
		assert(pm9InactiveAdapty.asks == 0, "case 41 (PM-09 row 1): an inactive layer must not be asked for a profile, was asked \(pm9InactiveAdapty.asks) time(s)")

		// 42. PM-09 row 2 — a profile request that hangs is cut at the SCREEN deadline (`waitingTimeout`),
		//     not at `sourceTimeout` and not at the SDK's own ten seconds.
		let pm9HangAdapty = FakeAdapty(answer: decodedProfile(subscriptions: ["year.sub": pm9Year]), delay: 5)
		let pm9HangService = PremiumService(store: SpyStore(), adapty: pm9HangAdapty, apple: nil, levels: ["premium"], sourceTimeout: 5, waitingTimeout: 0.3)
		let pm9Hang = ActiveSubscriptionsProbe(asking: pm9HangService)
		wait(3) { !pm9Hang.answers.isEmpty }
		assert(pm9Hang.answers == [nil], "case 42 (PM-09 row 2): a profile that never comes must answer nil, got \(pm9Hang.answers)")
		assert(pm9HangAdapty.asks == 1, "case 42 (PM-09 row 2): Adapty must have been asked once, got \(pm9HangAdapty.asks)")
		let pm9HangAfter = pm9Hang.firstAnswerAfter ?? 99
		assert(pm9HangAfter >= 0.25 && pm9HangAfter < 1, "case 42 (PM-09 row 2): nil must come at the 0.3s screen deadline, not at sourceTimeout 5s — took \(pm9HangAfter)s")

		// 43. PM-09 row 3 — offline, the SDK hands over its saved profile and that is an answer: the set is
		//     taken from it as is. A date in the past on an `is_active` subscription changes nothing.
		let pm9StaleAdapty = FakeAdapty(answer: decodedProfile(subscriptions: ["week.sub": subscriptionJSON("week.sub", active: true, expiresAt: now - 2 * hour)]))
		let pm9StaleService = PremiumService(store: SpyStore(), adapty: pm9StaleAdapty, apple: nil, levels: ["premium"], sourceTimeout: 5)
		let pm9Stale = ActiveSubscriptionsProbe(asking: pm9StaleService)
		wait { !pm9Stale.answers.isEmpty }
		assert(pm9Stale.answers == [["week.sub"]], "case 43 (PM-09 row 3): the saved profile's set must be returned as is, got \(pm9Stale.answers)")

		// 44. PM-09 row 4 — Adapty answers after the deadline: one callback, nil, and the late answer is
		//     dropped without a word. Counted again after the late answer has certainly landed.
		let pm9LateAdapty = FakeAdapty(answer: decodedProfile(subscriptions: ["year.sub": pm9Year]), delay: 0.5)
		let pm9LateService = PremiumService(store: SpyStore(), adapty: pm9LateAdapty, apple: nil, levels: ["premium"], sourceTimeout: 5, waitingTimeout: 0.2)
		let pm9Late = ActiveSubscriptionsProbe(asking: pm9LateService)
		wait { !pm9Late.answers.isEmpty }
		assert(pm9Late.answers == [nil], "case 44 (PM-09 row 4): the deadline wins, the answer is nil, got \(pm9Late.answers)")
		Thread.sleep(forTimeInterval: 0.6)
		RunLoop.current.run(until: Date().addingTimeInterval(0.1))
		assert(pm9Late.answers.count == 1, "case 44 (PM-09 row 4): the late answer must not call back again, got \(pm9Late.answers)")

		// 45. PM-09 row 5 — two calls at once are two independent runs, each with its own single callback.
		let pm9PairAdapty = FakeAdapty(answer: decodedProfile(subscriptions: ["year.sub": pm9Year]), delay: 0.1)
		let pm9PairService = PremiumService(store: SpyStore(), adapty: pm9PairAdapty, apple: nil, levels: ["premium"], sourceTimeout: 5, waitingTimeout: 1)
		let pm9First = ActiveSubscriptionsProbe(asking: pm9PairService)
		let pm9Second = ActiveSubscriptionsProbe(asking: pm9PairService)
		wait { !pm9First.answers.isEmpty && !pm9Second.answers.isEmpty }
		RunLoop.current.run(until: Date().addingTimeInterval(0.2))
		assert(pm9First.answers == [["year.sub"]] && pm9Second.answers == [["year.sub"]], "case 45 (PM-09 row 5): each call must get its own one answer, got \(pm9First.answers) and \(pm9Second.answers)")
		assert(pm9PairAdapty.asks == 2, "case 45 (PM-09 row 5): no deduplication — two calls, two requests, got \(pm9PairAdapty.asks)")

		// 46. PM-09 row 6 — read-only. A live premium the profile knows nothing about (a promo: access level,
		//     no subscriptions) is answered `[]` and the verdict is left exactly where it was: no store write,
		//     no notification, and the generation counter — visible in the apply log as "(gen N)" — does not
		//     move, so the next real refresh takes the very next number.
		let pm9Logs = LogLines()
		debugLogSink = pm9Logs.append
		let pm9ReadStore = SpyStore(cached: PremiumState(isPremium: true, source: .apple, isVerified: false), premium: true)
		let pm9ReadAdapty = FakeAdapty(answer: decodedProfile(subscriptions: [:]))
		let pm9ReadService = PremiumService(store: pm9ReadStore, adapty: pm9ReadAdapty, apple: nil, levels: ["premium"], sourceTimeout: 5)
		pm9ReadService.start()
		wait { pm9ReadAdapty.asks >= 1 }
		RunLoop.current.run(until: Date().addingTimeInterval(0.3))
		let pm9WritesBefore = pm9ReadStore.writes
		let pm9NotifiedBefore = pm9ReadStore.notified
		let pm9CachedBefore = pm9ReadStore.cached
		let pm9GensBefore = pm9Logs.generations
		let pm9Read = ActiveSubscriptionsProbe(asking: pm9ReadService)
		wait { !pm9Read.answers.isEmpty }
		assert(pm9Read.answers == [Set<String>()], "case 46 (PM-09 row 6): a profile with no subscriptions must answer [], not nil, got \(pm9Read.answers)")
		RunLoop.current.run(until: Date().addingTimeInterval(0.2))
		assert(pm9ReadStore.writes == pm9WritesBefore, "case 46 (PM-09 row 6): the operation must write nothing to the store, writes \(pm9WritesBefore) -> \(pm9ReadStore.writes)")
		assert(pm9ReadStore.notified == pm9NotifiedBefore, "case 46 (PM-09 row 6): the operation must notify nobody, \(pm9NotifiedBefore) -> \(pm9ReadStore.notified)")
		assert(pm9ReadStore.cached == pm9CachedBefore, "case 46 (PM-09 row 6): the cached verdict must be untouched")
		// A refresh that changes the verdict, so it logs its own number.
		pm9ReadAdapty.answer = profile(active: true, expiresAt: now + hour)
		pm9ReadService.refresh()
		wait { pm9Logs.generations.count > pm9GensBefore.count }
		debugLogSink = nil
		assert(!pm9GensBefore.isEmpty, "case 46 (PM-09 row 6): the apply log must show a generation before the call, or this row proves nothing")
		assert(pm9Logs.generations.last == pm9GensBefore.last.map { $0 + 1 }, "case 46 (PM-09 row 6): the generation counter must not move — the refresh after the call must be gen \(String(describing: pm9GensBefore.last.map { $0 + 1 })), got \(String(describing: pm9Logs.generations.last))")

		// 47. PM-09 row 7 — a profile with no `subscriptions` key at all is `[]`: Adapty did answer.
		let pm9NoKeyAdapty = FakeAdapty(answer: decodedProfile(subscriptions: nil))
		let pm9NoKeyService = PremiumService(store: SpyStore(), adapty: pm9NoKeyAdapty, apple: nil, levels: ["premium"], sourceTimeout: 5)
		let pm9NoKey = ActiveSubscriptionsProbe(asking: pm9NoKeyService)
		wait { !pm9NoKey.answers.isEmpty }
		assert(pm9NoKey.answers == [Set<String>()], "case 47 (PM-09 row 7): a profile without the subscriptions key must answer [], not nil, got \(pm9NoKey.answers)")

		// 48. PM-09 row 8 — exactly what Adapty marked active: weekly and yearly yes, a refunded one no, one
		//     in its grace period yes (its date is already in the past), an expired one no.
		let pm9MixedAdapty = FakeAdapty(answer: decodedProfile(subscriptions: [
			"week.sub": pm9Week,
			"year.sub": pm9Year,
			"refunded.sub": subscriptionJSON("refunded.sub", active: false, refund: true),
			"grace.sub": subscriptionJSON("grace.sub", active: true, grace: true, expiresAt: now - hour),
			"expired.sub": subscriptionJSON("expired.sub", active: false, expiresAt: now - hour)
		]))
		let pm9MixedService = PremiumService(store: SpyStore(), adapty: pm9MixedAdapty, apple: nil, levels: ["premium"], sourceTimeout: 5)
		let pm9Mixed = ActiveSubscriptionsProbe(asking: pm9MixedService)
		wait { !pm9Mixed.answers.isEmpty }
		assert(pm9Mixed.answers == [["week.sub", "year.sub", "grace.sub"]], "case 48 (PM-09 row 8): only what Adapty marked active — weekly, yearly, grace — got \(pm9Mixed.answers)")

		// 49. PM-09 row 9 — a subscription the app no longer sells (not among `productIds`) comes back as is.
		let pm9LegacyAdapty = FakeAdapty(answer: decodedProfile(subscriptions: ["week.sub": pm9Week, "retired.sub": subscriptionJSON("retired.sub", active: true)]))
		let pm9LegacyService = PremiumService(store: SpyStore(), adapty: pm9LegacyAdapty, apple: nil, levels: ["premium"], sourceTimeout: 5, productIds: ["week.sub", "year.sub"])
		let pm9Legacy = ActiveSubscriptionsProbe(asking: pm9LegacyService)
		wait { !pm9Legacy.answers.isEmpty }
		assert(pm9Legacy.answers == [["week.sub", "retired.sub"]], "case 49 (PM-09 row 9): no filter by productIds, got \(pm9Legacy.answers)")

		// 50. PM-09 row 10 — never inside the caller's own call, always on the main queue. Both paths, and each
		//     also from a background queue, where "on main" is a fact rather than a coincidence.
		let pm9AsyncInactive = ActiveSubscriptionsProbe(asking: pm9InactiveService)
		assert(!pm9AsyncInactive.answeredInsideCall, "case 50 (PM-09 row 10): the inactive-layer nil must not arrive inside the call")
		let pm9AsyncActive = ActiveSubscriptionsProbe(asking: pm9NoKeyService)
		assert(!pm9AsyncActive.answeredInsideCall, "case 50 (PM-09 row 10): the answer must not arrive inside the call either")
		let pm9Background = ActiveSubscriptionsProbe(asking: pm9InactiveService, onBackgroundQueue: true)
		let pm9BackgroundActive = ActiveSubscriptionsProbe(asking: pm9NoKeyService, onBackgroundQueue: true)
		wait { !pm9AsyncInactive.answers.isEmpty && !pm9AsyncActive.answers.isEmpty && !pm9Background.answers.isEmpty && !pm9BackgroundActive.answers.isEmpty }
		assert(pm9AsyncInactive.allOnMain && pm9AsyncActive.allOnMain, "case 50 (PM-09 row 10): the callback must run on the main queue")
		assert(pm9Background.answers == [nil] && pm9Background.allOnMain, "case 50 (PM-09 row 10): the inactive-layer nil, asked from a background queue, must still come on main")
		assert(pm9BackgroundActive.answers == [Set<String>()] && pm9BackgroundActive.allOnMain, "case 50 (PM-09 row 10): the answer, asked from a background queue, must still come on main")

		// 51. PM-09 row 11 — the app waking after a suspension, with the deadline and the answer both due at the
		//     same instant. A script cannot background an app; this is the nearest reproducible state, and it is
		//     the one where a second callback would come from. Thirty rounds, each exactly one.
		let pm9RaceAdapty = FakeAdapty(answer: decodedProfile(subscriptions: ["year.sub": pm9Year]), delay: 0.05)
		let pm9RaceService = PremiumService(store: SpyStore(), adapty: pm9RaceAdapty, apple: nil, levels: ["premium"], sourceTimeout: 5, waitingTimeout: 0.05)
		let pm9Race = (0 ..< 30).map { _ in ActiveSubscriptionsProbe(asking: pm9RaceService) }
		wait(3) { pm9Race.allSatisfy { !$0.answers.isEmpty } }
		RunLoop.current.run(until: Date().addingTimeInterval(0.4))
		assert(pm9Race.allSatisfy { $0.answers.count == 1 }, "case 51 (PM-09 row 11): every call must get exactly one callback, got counts \(pm9Race.map { $0.answers.count })")

		// 52. PM-09 row 12 — the trace: `info` says how many ids came, `error` names the timeout and the inactive
		//     layer; tag `PremiumService`.
		let pm9TraceLogs = LogLines()
		debugLogSink = pm9TraceLogs.append
		let pm9TraceOk = ActiveSubscriptionsProbe(asking: pm9MixedService)
		wait { !pm9TraceOk.answers.isEmpty }
		let pm9TraceHang = ActiveSubscriptionsProbe(asking: pm9HangService)
		let pm9TraceInactive = ActiveSubscriptionsProbe(asking: pm9InactiveService)
		wait(3) { !pm9TraceHang.answers.isEmpty && !pm9TraceInactive.answers.isEmpty }
		debugLogSink = nil
		let pm9Traced = pm9TraceLogs.all.filter { $0.contains("activeSubscriptionIds") }
		assert(pm9Traced.contains { $0.hasPrefix("[IntegrationKit][PremiumService] ") && $0.contains("3 active") }, "case 52 (PM-09 row 12): an info line with the id count (3) is missing, got \(pm9Traced)")
		assert(pm9Traced.filter { $0.hasPrefix("[IntegrationKit][PremiumService][error] ") }.count == 2, "case 52 (PM-09 row 12): the timeout and the inactive layer must each leave one error line, got \(pm9Traced)")
		assert(pm9Traced.contains { $0.contains("[error]") && $0.lowercased().contains("timeout") }, "case 52 (PM-09 row 12): the error line must name the timeout, got \(pm9Traced)")
		assert(pm9Traced.contains { $0.contains("[error]") && $0.lowercased().contains("inactive") }, "case 52 (PM-09 row 12): the error line must name the inactive layer, got \(pm9Traced)")

		// 53. PM-09 row 13 — the new member is declared on `PremiumServicing` with NO default implementation
		//     (an app's own fake must fail to compile until it answers: a minor release, 0.10.0), and
		//     `AdaptyPremiumProviding` did not grow — `profile()` already carries everything the operation needs.
		//     Compile-time facts, read from the source text: a runtime check cannot see a missing default.
		let pm9Sources = "Sources/IntegrationKit"
		let pm9Protocol = (try? String(contentsOfFile: "\(pm9Sources)/Premium/Protocols/PremiumServicing.swift", encoding: .utf8)) ?? ""
		assert(pm9Protocol.contains("func activeSubscriptionIds(completion: @escaping (Set<String>?) -> Void)"), "case 53 (PM-09 row 13): PremiumServicing must declare activeSubscriptionIds(completion:)")
		let pm9Provider = (try? String(contentsOfFile: "\(pm9Sources)/Premium/Protocols/AdaptyPremiumProviding.swift", encoding: .utf8)) ?? ""
		assert(!pm9Provider.contains("activeSubscription"), "case 53 (PM-09 row 13): AdaptyPremiumProviding must not grow a member for this")
		var pm9Defaults: [String] = []
		if let files = FileManager.default.enumerator(atPath: pm9Sources) {
			for case let file as String in files where file.hasSuffix(".swift") {
				let text = (try? String(contentsOfFile: "\(pm9Sources)/\(file)", encoding: .utf8)) ?? ""
				if text.contains("extension PremiumServicing") { pm9Defaults.append(file) }
			}
		}
		assert(pm9Defaults.isEmpty, "case 53 (PM-09 row 13): no default implementation may exist — extension PremiumServicing found in \(pm9Defaults)")

		print("PremiumService barrier, restore, purchase fallback, prices and activeSubscriptionIds: 53/53 OK")
	}
}

/// Case 31's Adapty. A separate fake rather than one more field on `FakeAdapty` on purpose: the risk
/// tables of PM-01…PM-06 quote `PremiumBarrierCheck.swift` line numbers, and a line added up there
/// moves every one of them. Appending at the bottom moves nothing.
final class StatefulPaywallAdapty: AdaptyPremiumProviding {
	var premiumObserver: ((AdaptyProfile, Bool) -> Void)?
	/// What Adapty says about the placement's paywall — case 31 moves it through all three values.
	var paywallStateAnswer: PaywallState = .unavailable

	func profile() async -> AdaptyProfile? { nil }
	func products(placement: String) async -> AdaptyProductsAnswer { .notReady }
	func buy(productId: String, placement: String) async -> PurchaseVerdict { .failed }
	func remoteValue<T>(placement: String, key: String) -> RemoteValue<T> { .notReady }
	func logPaywallOpen(placement: String) {}
	/// Pinned at `false` on purpose — case 31 asserts the facade does not derive one answer from the
	/// other, and it could not tell if this moved with `paywallStateAnswer`.
	func hasPaywall(placement: String) -> Bool { false }
	func paywallState(placement: String) -> PaywallState { paywallStateAnswer }
	func syncReceipt() {}
}

// `isActive` arrives as an extension rather than a stored property for the same reason case 31's
// fake was appended rather than folded into `FakeAdapty`: the risk tables of PM-01…PM-08 quote line
// numbers in this file, and a member added inside either class moves every one of them. Both fakes
// stand for a layer that came up — the cases above are about the barrier, not about activation.
extension FakeAdapty {
	var isActive: Bool { true }
}

extension StatefulPaywallAdapty {
	var isActive: Bool { true }
}

/// Case 32's Adapty: the layer that never came up. Every answer is the one `AdaptyService` gives
/// with `isActive == false` — and `products` is the interesting one, because `.notReady` is also
/// exactly what a live layer says while its paywall is still loading. The two are indistinguishable
/// from the answer alone, which is why the flag has to be asked for separately.
final class InactiveLayerAdapty: AdaptyPremiumProviding {
	var isActive: Bool { false }
	var premiumObserver: ((AdaptyProfile, Bool) -> Void)?

	func profile() async -> AdaptyProfile? { nil }
	func products(placement: String) async -> AdaptyProductsAnswer { .notReady }
	func buy(productId: String, placement: String) async -> PurchaseVerdict { .failed }
	func remoteValue<T>(placement: String, key: String) -> RemoteValue<T> { .notReady }
	func logPaywallOpen(placement: String) {}
	func hasPaywall(placement: String) -> Bool { false }
	func paywallState(placement: String) -> PaywallState { .unavailable }
	func syncReceipt() {}
}

/// Case 33's journal of profile writes. A file-scope global rather than a property on `FakeAdapty`
/// for the same reason `isActive` arrives as an extension: a member added inside either fake moves
/// every line number the PM-01…PM-08 risk tables quote. Case 33 clears it before each of its runs.
var fakeAdaptyProfileWrites: [String] = []

extension FakeAdapty {
	func setProfileValue(value: String, key: String) {
		fakeAdaptyProfileWrites.append("\(key)=\(value)")
	}
}

/// Cases 34-36's Adapty: the one that counts how many times it was asked. PM-02 rows 7-10 are about
/// whether the question gets asked again at all, and the store cannot show that — a barrier that
/// resolves to the state already cached writes nothing, so a retry that ran and a retry that never
/// ran look identical from there. Appended at the bottom for the same reason as the fakes above.
final class CountingAdapty: AdaptyPremiumProviding {
	var isActive: Bool { true }
	var premiumObserver: ((AdaptyProfile, Bool) -> Void)?
	/// What it answers when asked. Mutable so a case can turn silence into an answer mid-run.
	var answer: AdaptyProfile?
	private let lock = NSLock()
	private var count = 0

	init(answer: AdaptyProfile?) {
		self.answer = answer
	}

	/// How many times the barrier has asked for a profile.
	var asks: Int {
		lock.lock()
		defer { lock.unlock() }
		return count
	}

	func profile() async -> AdaptyProfile? {
		// The lock is taken in a synchronous helper: `NSLock` is unavailable from an async context
		// and is a hard error in Swift 6 language mode.
		record()
	}

	private func record() -> AdaptyProfile? {
		lock.lock()
		defer { lock.unlock() }
		count += 1
		return answer
	}

	func products(placement: String) async -> AdaptyProductsAnswer { .notReady }
	func buy(productId: String, placement: String) async -> PurchaseVerdict { .failed }
	func remoteValue<T>(placement: String, key: String) -> RemoteValue<T> { .notReady }
	func logPaywallOpen(placement: String) {}
	func hasPaywall(placement: String) -> Bool { false }
	func paywallState(placement: String) -> PaywallState { .unavailable }
	func syncReceipt() {}
	func setProfileValue(value: String, key: String) {}
}

extension StatefulPaywallAdapty {
	func setProfileValue(value: String, key: String) {}
}

extension InactiveLayerAdapty {
	func setProfileValue(value: String, key: String) {}
}

// MARK: - PM-09 (cases 41-53). Appended here for the same reason as everything above: a line added
// higher up moves the line numbers the PM-01…PM-08 risk tables quote.

/// Case 41's Adapty: a layer that never came up, but one that WOULD answer — slowly, with a profile —
/// if it were asked. `InactiveLayerAdapty` answers `nil` at once either way, so it could not tell
/// "the service skipped the question" from "the service asked and got nothing back".
final class InactiveProbeAdapty: AdaptyPremiumProviding {
	var isActive: Bool { false }
	var premiumObserver: ((AdaptyProfile, Bool) -> Void)?
	private let answer: AdaptyProfile?
	private let delay: TimeInterval
	private let lock = NSLock()
	private var count = 0

	init(answer: AdaptyProfile?, delay: TimeInterval) {
		self.answer = answer
		self.delay = delay
	}

	/// How many times anybody asked for a profile.
	var asks: Int {
		lock.lock()
		defer { lock.unlock() }
		return count
	}

	func profile() async -> AdaptyProfile? {
		record()
		try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
		return answer
	}

	private func record() {
		lock.lock()
		count += 1
		lock.unlock()
	}

	func products(placement: String) async -> AdaptyProductsAnswer { .notReady }
	func buy(productId: String, placement: String) async -> PurchaseVerdict { .failed }
	func remoteValue<T>(placement: String, key: String) -> RemoteValue<T> { .notReady }
	func logPaywallOpen(placement: String) {}
	func hasPaywall(placement: String) -> Bool { false }
	func paywallState(placement: String) -> PaywallState { .unavailable }
	func syncReceipt() {}
	func setProfileValue(value: String, key: String) {}
}

/// `activeSubscriptionIds` seen from the caller's side: every answer it gave, on which queue, how long
/// it took, and whether any of it arrived inside the call itself. The callback is read on the main
/// thread only — the contract says it runs there, and the check pumps the main run loop to see it.
final class ActiveSubscriptionsProbe {
	private(set) var answers: [Set<String>?] = []
	private(set) var allOnMain = true
	private(set) var firstAnswerAfter: TimeInterval?
	private(set) var answeredInsideCall = false
	private let startedAt = Date()

	init(asking service: PremiumServicing, onBackgroundQueue: Bool = false) {
		let ask = { [self] in
			service.activeSubscriptionIds { [weak self] ids in
				guard let self else { return }
				if !Thread.isMainThread { allOnMain = false }
				if firstAnswerAfter == nil { firstAnswerAfter = Date().timeIntervalSince(startedAt) }
				answers.append(ids)
			}
		}
		if onBackgroundQueue {
			DispatchQueue.global().async(execute: ask)
		} else {
			ask()
			answeredInsideCall = !answers.isEmpty
		}
	}
}

/// The log, collected. `debugLog` calls come from the cooperative pool as well as from main, so the
/// lines go behind a lock.
final class LogLines {
	private let lock = NSLock()
	private var storage: [String] = []

	func append(_ line: String) {
		lock.lock()
		storage.append(line)
		lock.unlock()
	}

	var all: [String] {
		lock.lock()
		defer { lock.unlock() }
		return storage
	}

	/// The generation numbers `PremiumService.apply` printed, in order — the only place the counter is
	/// visible from outside. A dropped answer prints another line and is not counted here.
	var generations: [Int] {
		all.filter { $0.contains("apply: isPremium") }.compactMap { line in
			guard let open = line.range(of: "(gen ", options: .backwards) else { return nil }
			return Int(line[open.upperBound...].prefix { $0.isNumber })
		}
	}
}

/// One subscription as the server sends it: every key the SDK requires, `expires_at` only when given.
func subscriptionJSON(_ id: String, active: Bool, grace: Bool = false, refund: Bool = false, expiresAt: Date? = nil) -> [String: Any] {
	var json: [String: Any] = [
		"store": "app_store",
		"vendor_product_id": id,
		"vendor_transaction_id": "transaction-\(id)",
		"vendor_original_transaction_id": "transaction-\(id)",
		"is_active": active,
		"is_lifetime": false,
		"activated_at": 0,
		"is_in_grace_period": grace,
		"is_sandbox": true,
		"is_refund": refund,
		"will_renew": !refund,
	]
	if let expiresAt {
		json["expires_at"] = expiresAt.timeIntervalSince1970
	}
	return json
}

/// A profile built by the decoder, the way the SDK builds one. `nil` leaves the `subscriptions` key
/// out altogether — a profile with no subscriptions carries none (PM-09 row 7).
func decodedProfile(subscriptions: [String: [String: Any]]?) -> AdaptyProfile {
	var payload: [String: Any] = ["profile_id": "pm09-profile", "segment_hash": "pm09"]
	if let subscriptions {
		payload["subscriptions"] = subscriptions
	}
	let decoder = JSONDecoder()
	decoder.dateDecodingStrategy = .secondsSince1970
	guard
		let data = try? JSONSerialization.data(withJSONObject: payload),
		let profile = try? decoder.decode(AdaptyProfile.self, from: data)
	else {
		fatalError("PM-09 fixture: the profile did not decode")
	}
	return profile
}
