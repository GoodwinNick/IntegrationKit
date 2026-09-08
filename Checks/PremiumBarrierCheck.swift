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
	var premiumObserver: ((AdaptyProfile) -> Void)?
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

	func products(placement: String) async -> [PremiumProduct] { catalogue }
	func buy(productId: String, placement: String) async -> AdaptyPurchaseResult { buyResult }
	func remoteValue<T>(placement: String, key: String) -> T? { nil }
	func logPaywallOpen(placement: String) {}
	func hasPaywall(placement: String) -> Bool { false }
}

/// The Apple side, same idea.
final class FakeApple: AppleSubscribing {
	var receipt: Bool?
	var delay: TimeInterval
	var restoreResult: RestoreOutcome = .nothingToRestore
	var purchaseResult: PurchaseOutcome = .failed
	/// Set by `purchase` — case 8 asserts the fallback was actually reached, not just that the
	/// outcome happened to match.
	var purchasedProductId: String?

	init(receipt: Bool?, delay: TimeInterval = 0) {
		self.receipt = receipt
		self.delay = delay
	}

	func checkReceipt() async -> Bool? {
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
		let apple = FakeApple(receipt: true, delay: 0.01)
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
		let receiptApple = FakeApple(receipt: true)
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
		let quickApple = FakeApple(receipt: true, delay: 0.01)
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

		print("PremiumService barrier, restore, purchase fallback and prices: 10/10 OK")
	}
}
