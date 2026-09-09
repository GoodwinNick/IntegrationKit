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
	var buyResult: AdaptyPurchaseResult = .failed
	var catalogue: [PremiumProduct] = []

	init(answer: AdaptyProfile?, delay: TimeInterval = 0) {
		self.answer = answer
		self.delay = delay
	}

	func profile() async -> AdaptyProfile? {
		if delay > 0 {
			try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
		}
		return answer
	}

	func products(placement: String) async -> AdaptyProductsAnswer {
		catalogue.isEmpty ? .notReady : .products(catalogue)
	}

	func buy(productId: String, placement: String) async -> AdaptyPurchaseResult { buyResult }
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
		silentAdapty.answer = profile(active: false)
		silentService.refresh()
		assert(wait { silentStore.cached?.isPremium == false }, "case 2: a second refresh must run after Adapty went silent once")

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
		assert(
			freshBuyStore.cached == PremiumState(isPremium: true, source: .apple, isVerified: false, expiresAt: nil, localPurchase: true),
			"case 19: a stale verified denial must not swallow a fresh purchase, expected unverified premium from .apple, got \(String(describing: freshBuyStore.cached))"
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

		// 23. PM-06 row 2: the lock buys atomicity per apply, and NOTHING beyond that. A refresh that
		//     started earlier and finished later overwrites a push that carried the fresher truth —
		//     last writer wins, not freshest answer. The risk row calls this a recognised limit
		//     ("саме так і працює"), so this case pins the behaviour, it does not object to it.
		let raceStore = SpyStore()
		let raceAdapty = FakeAdapty(answer: profile(active: false))
		let raceService = PremiumService(store: raceStore, adapty: raceAdapty, apple: nil, levels: ["premium"], sourceTimeout: 1)
		raceService.start()
		assert(wait { raceStore.cached?.source == .adapty }, "case 23: start() must settle on Adapty's answer first")
		assert(raceStore.writes == 2, "case 23: seed then start's refresh — exactly 2 writes before the race, got \(raceStore.writes)")
		// The stale reader: it reads the SAME inactive profile, it just takes 0.3s to come back.
		raceAdapty.delay = 0.3
		raceService.refresh()
		Thread.sleep(forTimeInterval: 0.1)
		// The fresher truth, arriving 0.2s BEFORE the refresh that started before it.
		raceAdapty.premiumObserver?(profile(active: true, expiresAt: now + hour), true)
		assert(raceStore.cached?.isPremium == true, "case 23: the push must land first, expected isPremium true right after it, got \(String(describing: raceStore.cached?.isPremium))")
		assert(wait { raceStore.cached?.isPremium == false }, "case 23: the older, slower refresh must land last and overwrite the fresher push")
		assert(
			raceStore.cached == PremiumState(isPremium: false, source: .adapty, isVerified: true, expiresAt: nil),
			"case 23: the last writer wins — expected the stale refresh's verified inactive verdict, got \(String(describing: raceStore.cached))"
		)
		assert(raceStore.writes == 4, "case 23: seed, start's refresh, the push, the stale refresh — exactly 4 writes, got \(raceStore.writes)")
		assert(raceStore.notified == 2, "case 23: the flag went false-true-false — exactly 2 notifications, got \(raceStore.notified)")

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

		// 26. PM-04 row 11: Apple took the money and Adapty could not confirm it. Both halves matter and
		//     both live in the facade, not in `AdaptyService`: the app must see `.pending` rather than a
		//     failure it would offer to retry, and the StoreKit fallback must NOT run — it would ask a
		//     user who has already paid to pay a second time. Access is granted on the strength of the
		//     payment, through the same local-purchase mark a normal purchase uses.
		let paidStore = SpyStore(cached: .free)
		let paidAdapty = FakeAdapty(answer: nil)
		paidAdapty.buyResult = .paidUnconfirmed
		let paidApple = FakeApple(receipt: nil)
		let paidService = PremiumService(store: paidStore, adapty: paidAdapty, apple: paidApple, levels: ["premium"], sourceTimeout: 1)
		var paidOutcome: PurchaseOutcome?
		paidService.purchase("year.sub", placement: "main") { paidOutcome = $0 }
		assert(wait { paidOutcome != nil }, "case 26: purchase must call back")
		assert(paidOutcome == .pending, "case 26: money taken and unconfirmed maps to exactly .pending, never .failed, got \(String(describing: paidOutcome))")
		assert(paidApple.purchasedProductId == nil, "case 26: the StoreKit fallback must NOT run after a paid-but-unconfirmed purchase — that is a second charge; it was asked to buy \(String(describing: paidApple.purchasedProductId))")
		assert(paidService.isPremium == true, "case 26: a purchase Apple already charged for must grant access, got \(paidService.isPremium)")
		assert(paidStore.cached?.localPurchase == true, "case 26: it must carry the local-purchase mark like any other payment on this device, got \(String(describing: paidStore.cached))")

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
		//     sees the paywall on every cold start. `premium-resolver-check.sh` case 9 pins the rule
		//     itself; this case pins the wiring — that the observer forwards provenance at all, through
		//     the real `PremiumAccess(profile:levels:isVerified:)` conversion.
		let provenanceStore = SpyStore(cached: PremiumState(isPremium: true, source: .adapty, isVerified: true, expiresAt: now + hour), premium: true)
		let provenanceAdapty = FakeAdapty(answer: nil)
		let provenanceService = PremiumService(store: provenanceStore, adapty: provenanceAdapty, apple: nil, levels: ["premium"], sourceTimeout: 1)
		provenanceService.start()
		Thread.sleep(forTimeInterval: 0.3)
		assert(provenanceStore.writes == 0, "case 30: a live cache and a silent source change nothing — expected 0 writes after start(), got \(provenanceStore.writes)")
		provenanceAdapty.premiumObserver?(profile(active: false), false)
		assert(provenanceService.isPremium == true, "case 30: an unverified push saying inactive must not close access, got \(provenanceService.isPremium)")
		assert(provenanceStore.writes == 0, "case 30: it resolves back to the same cached verdict — expected still 0 writes, got \(provenanceStore.writes)")
		assert(provenanceStore.notified == 0, "case 30: nothing changed — expected 0 notifications, got \(provenanceStore.notified)")
		// The very same profile, this time from the network. That one is Adapty's actual verdict.
		provenanceAdapty.premiumObserver?(profile(active: false), true)
		assert(provenanceService.isPremium == false, "case 30: the same denial, verified, must revoke — got \(provenanceService.isPremium)")
		assert(provenanceStore.cached == PremiumState(isPremium: false, source: .adapty, isVerified: true, expiresAt: nil), "case 30: expected Adapty's own verified denial, got \(String(describing: provenanceStore.cached))")
		assert(provenanceStore.notified == 1, "case 30: exactly 1 .premiumDidChange, got \(provenanceStore.notified)")

		print("PremiumService barrier, restore, purchase fallback and prices: 30/30 OK")
	}
}
