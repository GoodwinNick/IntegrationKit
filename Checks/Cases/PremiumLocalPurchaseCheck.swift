//
//  PremiumLocalPurchaseCheck.swift
//  IntegrationKit
//
//  Covers PM-03 rows 10-17, PM-04 rows 9-10, PM-05 row 8, PM-08 row 7 and PM-07 row 9 — the
//  local-purchase mark. Written as the spec for two things that did not exist when it was first
//  run: `PremiumResolver.resolve` reading its `localPurchase` parameter instead of accepting and
//  ignoring it, and `PremiumService` writing `localPurchase: true` onto a freshly resolved state
//  after a purchase, a restore or a delivered transaction. Both landed, and all twenty asserts are
//  green — a failure here now means the mark was lost, not that the work is still pending.
//
//  This check does not stop at the first failing row: every row runs, every failure is collected,
//  and the summary at the end reports all of them with a non-zero exit code.
//  Run:  ./Checks/premium-local-purchase-check.sh
//

import Adapty
import Foundation

/// Counts what the real `UserDefaultsPremiumStore` does — same as `PremiumBarrierCheck`'s.
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

/// An Adapty that answers whatever it is told. `syncReceiptCount` counts calls to the new
/// `syncReceipt()` — nothing in `PremiumService` calls it yet, so it must stay 0 everywhere (T15).
final class FakeAdapty: AdaptyPremiumProviding {
	var premiumObserver: ((AdaptyProfile, Bool) -> Void)?
	var answer: AdaptyProfile?
	var buyResult: PurchaseVerdict = .failed
	private let lock = NSLock()
	private var syncCalls = 0

	init(answer: AdaptyProfile?) {
		self.answer = answer
	}

	var syncReceiptCount: Int {
		lock.lock()
		defer { lock.unlock() }
		return syncCalls
	}

	func profile() async -> AdaptyProfile? { answer }
	func products(placement: String) async -> AdaptyProductsAnswer { .notReady }
	func buy(productId: String, placement: String) async -> PurchaseVerdict { buyResult }
	func remoteValue<T>(placement: String, key: String) -> RemoteValue<T> { .notReady }
	func logPaywallOpen(placement: String) {}
	func hasPaywall(placement: String) -> Bool { false }
	func paywallState(placement: String) -> PaywallState { .unavailable }

	func syncReceipt() {
		lock.lock()
		syncCalls += 1
		lock.unlock()
	}
}

/// The Apple side, same idea — settable purchase/restore/checkReceipt results plus a products
/// catalogue for the PM-07 row 9 fallback (T20).
final class FakeApple: AppleSubscribing {
	var receipt: ReceiptAnswer?
	var restoreResult: RestoreOutcome = .nothingToRestore
	var purchaseResult: PurchaseOutcome = .failed
	var catalogue: [String: PremiumProduct] = [:]

	init(receipt: ReceiptAnswer?) {
		self.receipt = receipt
	}

	func checkReceipt() async -> ReceiptAnswer? { receipt }
	func restore() async -> RestoreOutcome { restoreResult }
	func purchase(productId: String) async -> PurchaseOutcome { purchaseResult }
	func products(ids: Set<String>) async -> [String: PremiumProduct] { catalogue.filter { ids.contains($0.key) } }
}

@main
enum PremiumLocalPurchaseCheck {
	static var failures: [String] = []

	/// Records a failure instead of trapping — one failing row must not stop every row after it
	/// from running.
	static func check(_ condition: @autoclosure () -> Bool, _ message: @autoclosure () -> String) {
		guard !condition() else { return }
		let text = message()
		failures.append(text)
		print("FAILED: \(text)")
	}

	static func profile(active: Bool, expiresAt: Date? = nil) -> AdaptyProfile {
		AdaptyProfile(accessLevels: [
			"premium": AdaptyProfile.AccessLevel(id: "premium", isActive: active, isLifetime: false, expiresAt: expiresAt)
		])
	}

	/// Polls instead of awaiting, same as the other checks: `refresh()`-style calls are
	/// fire-and-forget, and completions come back on the main queue.
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
		let hour: TimeInterval = 3600

		// MARK: - Part A: PremiumResolver, called directly.

		// T1 — PM-03 row 10: an unverified local purchase in the cache must survive an inactive
		// Adapty answer — the mark is supposed to hold until Adapty speaks about THIS purchase.
		let t1Cached = PremiumState(isPremium: true, source: .apple, isVerified: false, expiresAt: now + hour, localPurchase: true)
		let t1 = PremiumResolver.resolve(adapty: PremiumAccess(isActive: false), apple: nil, cached: t1Cached, now: now)
		check(t1.isPremium == true, "PM-03 row 10: an inactive Adapty must be ignored while the local-purchase mark stands — expected isPremium true, got \(t1.isPremium)")
		check(t1.localPurchase == true, "PM-03 row 10: expected the mark to survive, localPurchase true, got \(t1.localPurchase)")

		// T2 — PM-03 row 11: once Adapty confirms (active), the mark has done its job and drops.
		let t2Cached = PremiumState(isPremium: true, source: .apple, isVerified: false, expiresAt: now + hour, localPurchase: true)
		let t2 = PremiumResolver.resolve(adapty: PremiumAccess(isActive: true, expiresAt: now + hour), apple: nil, cached: t2Cached, now: now)
		check(t2.isPremium == true, "PM-03 row 11: expected isPremium true, got \(t2.isPremium)")
		check(t2.isVerified == true, "PM-03 row 11: expected isVerified true, got \(t2.isVerified)")
		check(t2.source == .adapty, "PM-03 row 11: expected source .adapty, got \(t2.source)")
		check(t2.localPurchase == false, "PM-03 row 11: Adapty confirmed — expected the mark to drop, localPurchase false, got \(t2.localPurchase)")

		// T3 — PM-03 row 12: an inactive, verified Adapty answer still revokes an expired marked
		// cache, and clears the mark along with it.
		let t3Cached = PremiumState(isPremium: true, source: .apple, isVerified: false, expiresAt: now - hour, localPurchase: true)
		let t3 = PremiumResolver.resolve(adapty: PremiumAccess(isActive: false), apple: ReceiptAnswer(isActive: false, expiresAt: nil), cached: t3Cached, now: now)
		check(t3.isPremium == false, "PM-03 row 12: expected isPremium false, got \(t3.isPremium)")
		check(t3.localPurchase == false, "PM-03 row 12: a revoke must clear the mark too, expected localPurchase false, got \(t3.localPurchase)")

		// T4 — PM-03 row 13: nobody answered, the cache is still valid — the mark rides through
		// the cache branch untouched (branch 2 just hands the cache back as-is).
		let t4Cached = PremiumState(isPremium: true, source: .apple, isVerified: false, expiresAt: now + hour, localPurchase: true)
		let t4 = PremiumResolver.resolve(adapty: nil, apple: nil, cached: t4Cached, now: now)
		check(t4.isPremium == true, "PM-03 row 13: expected isPremium true, got \(t4.isPremium)")
		check(t4.localPurchase == true, "PM-03 row 13: expected the mark carried through, localPurchase true, got \(t4.localPurchase)")

		// T5 — PM-03 row 14: nothing cached, nobody answered, but a local purchase IS itself a
		// receipt saying yes.
		let t5 = PremiumResolver.resolve(adapty: nil, apple: nil, cached: nil, localPurchase: true, now: now)
		check(t5.isPremium == true, "PM-03 row 14: a bare local purchase must itself grant premium — expected isPremium true, got \(t5.isPremium)")
		check(t5.source == .apple, "PM-03 row 14: expected source .apple, got \(t5.source)")
		check(t5.isVerified == false, "PM-03 row 14: expected isVerified false, got \(t5.isVerified)")
		check(t5.localPurchase == true, "PM-03 row 14: expected localPurchase true, got \(t5.localPurchase)")

		// T6 — PM-03 row 15: no mark, Adapty active — localPurchase must stay false.
		let t6 = PremiumResolver.resolve(adapty: PremiumAccess(isActive: true, expiresAt: now + hour), apple: nil, cached: nil, localPurchase: false, now: now)
		check(t6.localPurchase == false, "PM-03 row 15: expected localPurchase false, got \(t6.localPurchase)")

		// T7 — PM-03 row 16: the receipt's own expiresAt must survive branch 3. It does — branch 3
		// carries `receipt.expiresAt` into the verdict. (This comment used to claim the date was
		// hardcoded to nil; that was true before row 16 was fixed and has been stale since.)
		let t7 = PremiumResolver.resolve(adapty: nil, apple: ReceiptAnswer(isActive: true, expiresAt: now + hour), cached: nil, now: now)
		check(t7.isPremium == true, "PM-03 row 16: expected isPremium true, got \(t7.isPremium)")
		check(t7.expiresAt == now + hour, "PM-03 row 16: branch 3 must carry the receipt's expiresAt through — expected \(now + hour), got \(String(describing: t7.expiresAt))")

		// T8 — table B row 4: Adapty inactive but the mark stands, AND a fresh, active Apple
		// receipt is on the table too — the receipt's expiry should win, and the mark should survive.
		let t8Cached = PremiumState(isPremium: true, source: .apple, isVerified: false, expiresAt: now - hour, localPurchase: true)
		let t8 = PremiumResolver.resolve(adapty: PremiumAccess(isActive: false), apple: ReceiptAnswer(isActive: true, expiresAt: now + hour), cached: t8Cached, now: now)
		check(t8.isPremium == true, "table B row 4: expected isPremium true, got \(t8.isPremium)")
		check(t8.expiresAt == now + hour, "table B row 4: expected expiresAt \(now + hour), got \(String(describing: t8.expiresAt))")
		check(t8.localPurchase == true, "table B row 4: expected localPurchase true, got \(t8.localPurchase)")

		// T9 — table B row 6: same starting cache as T8, but this time there is no receipt on the
		// table — Adapty's inactive answer must win outright and clear the mark.
		let t9Cached = PremiumState(isPremium: true, source: .apple, isVerified: false, expiresAt: now - hour, localPurchase: true)
		let t9 = PremiumResolver.resolve(adapty: PremiumAccess(isActive: false), apple: nil, cached: t9Cached, now: now)
		check(t9.isPremium == false, "table B row 6: expected isPremium false, got \(t9.isPremium)")
		check(t9.localPurchase == false, "table B row 6: expected localPurchase false, got \(t9.localPurchase)")

		// T10 — regression, PM-03 row 1: no mark at all — Adapty still revokes over a positive
		// receipt. Must be GREEN already; red here would mean the existing ladder broke.
		let t10Cached = PremiumState(isPremium: true, source: .apple, isVerified: false, localPurchase: false)
		let t10 = PremiumResolver.resolve(adapty: PremiumAccess(isActive: false), apple: ReceiptAnswer(isActive: true, expiresAt: nil), cached: t10Cached, now: now)
		check(t10.isPremium == false, "PM-03 row 1 (regression): without the mark, Adapty must still revoke — expected isPremium false, got \(t10.isPremium)")

		// T11 — PM-03 row 17: an expired, unmarked cache with nobody left to ask. Also GREEN
		// already — this pins the real behaviour behind the row's lying comment.
		let t11Cached = PremiumState(isPremium: true, source: .apple, isVerified: false, expiresAt: now - hour, localPurchase: false)
		let t11 = PremiumResolver.resolve(adapty: nil, apple: nil, cached: t11Cached, now: now)
		check(t11.isPremium == false, "PM-03 row 17: an expired unmarked cache must not grant premium — expected isPremium false, got \(t11.isPremium)")

		// T12 — PM-03 row 13 (expired): same shape as T4, but the cache has already expired — the
		// mark must never resurrect it.
		let t12Cached = PremiumState(isPremium: true, source: .apple, isVerified: false, expiresAt: now - hour, localPurchase: true)
		let t12 = PremiumResolver.resolve(adapty: nil, apple: nil, cached: t12Cached, now: now)
		check(t12.isPremium == false, "PM-03 row 13 (expired): an expired cache must not grant premium even when marked — expected isPremium false, got \(t12.isPremium)")
		check(t12.localPurchase == false, "PM-03 row 13 (expired): the mark must not survive an expired cache — expected localPurchase false, got \(t12.localPurchase)")

		// T21 — PM-03 rows 7 and 10 crossed, and the one combination no table here ever fed: a
		// verified Adapty denial arriving in the SAME call as a mark passed by PARAMETER, with a
		// cache present. Every other marked case above takes its mark from `cached.localPurchase` and
		// leaves the parameter false, so the cache demotion has never once run against a live
		// verified denial — the gap looked closed because its two halves were covered apart.
		// The denial must change nothing: `!mark` keeps branch 1 shut, the demoted denial-cache is
		// disqualified from branch 2, and the mark's own receipt opens access.
		// (Numbered past part B: the pair was added after both parts were already written.)
		let deniedCache = PremiumState(isPremium: false, source: .adapty, isVerified: true, expiresAt: nil, localPurchase: false)
		let t21 = PremiumResolver.resolve(adapty: PremiumAccess(isActive: false), apple: nil, cached: deniedCache, localPurchase: true, now: now)
		check(t21.isPremium == true, "PM-03 rows 7+10: a verified denial must not swallow a purchase that just went through — expected isPremium true, got \(t21.isPremium)")
		check(t21.source == .apple, "PM-03 rows 7+10: the verdict comes from the purchase, expected source .apple, got \(t21.source)")
		check(t21.localPurchase == true, "PM-03 rows 7+10: expected the mark to survive the denial, localPurchase true, got \(t21.localPurchase)")

		// T22 — the other half, and it is not decoration. With only T21 the `!mark` branch could be
		// "fixed" by never reaching it at all. Same cache, same mark, Adapty silent instead of
		// denying: the verdict has to be identical, and that identity is what proves the denial was
		// ignored rather than simply absent.
		let t22 = PremiumResolver.resolve(adapty: nil, apple: nil, cached: deniedCache, localPurchase: true, now: now)
		check(t22 == t21, "PM-03 rows 7+10: silence and a verified denial must give the same verdict under a standing mark — expected \(t21), got \(t22)")

		// MARK: - Part A2: the mark's birth date and ageing (PM-03 rows 19-21).

		// The window the mark opens had no way to close except Adapty's own confirmation, which may
		// never arrive — that was the eternal premium. These five pin the second stop.
		let day: TimeInterval = 24 * 3600
		let markedPremium = { (since: Date?) in
			PremiumState(isPremium: true, source: .apple, isVerified: false, expiresAt: nil, localPurchase: true, localPurchaseAt: since)
		}

		// T23 — PM-03 row 19: past the deadline the mark stops demoting Adapty, and the verified
		// denial it was holding back finally lands. This is the whole point: without it, a receipt
		// that brought no date plus an Adapty that never confirms means premium forever.
		let t23 = PremiumResolver.resolve(adapty: PremiumAccess(isActive: false), apple: nil, cached: markedPremium(now - 8 * day), now: now)
		check(t23.isPremium == false, "PM-03 row 19: a mark past its deadline must stop demoting Adapty — expected isPremium false, got \(t23.isPremium)")
		check(t23.localPurchase == false, "PM-03 row 19: the expired mark must be cleared, expected localPurchase false, got \(t23.localPurchase)")
		check(t23.localPurchaseAt == nil, "PM-03 row 19: no mark means no date, expected nil, got \(String(describing: t23.localPurchaseAt))")

		// T24 — PM-03 row 19, the other side of the same deadline: one day short of it the mark still
		// works exactly as before, and its date comes through untouched.
		let t24Since = now - 6 * day
		let t24 = PremiumResolver.resolve(adapty: PremiumAccess(isActive: false), apple: nil, cached: markedPremium(t24Since), now: now)
		check(t24.isPremium == true, "PM-03 row 19: a mark inside its deadline must still hold — expected isPremium true, got \(t24.isPremium)")
		check(t24.localPurchaseAt == t24Since, "PM-03 row 20: the birth date must come through unchanged, expected \(t24Since), got \(String(describing: t24.localPurchaseAt))")

		// T25 — PM-03 row 21: a cache written before 0.6.0 carries the mark without a date. Reading
		// that as "infinitely old" would take premium away from live payers on the upgrade alone, so
		// it counts as brand new and gets stamped once, here.
		let t25 = PremiumResolver.resolve(adapty: PremiumAccess(isActive: false), apple: nil, cached: markedPremium(nil), now: now)
		check(t25.isPremium == true, "PM-03 row 21: a dateless mark counts as brand new — expected isPremium true, got \(t25.isPremium)")
		check(t25.localPurchaseAt == now, "PM-03 row 21: the missing date is stamped with the current moment, expected \(now), got \(String(describing: t25.localPurchaseAt))")

		// T26 — PM-03 row 20: the same unfinished transaction is handed over by the payment queue on
		// every launch. It re-asserts the mark, and the date must NOT move — otherwise one repeating
		// event pushes the deadline out forever and the ageing never happens.
		let t26 = PremiumResolver.resolve(adapty: nil, apple: nil, cached: markedPremium(t24Since), localPurchase: true, now: now)
		check(t26.localPurchaseAt == t24Since, "PM-03 row 20: re-asserting a live mark must not move its date, expected \(t24Since), got \(String(describing: t26.localPurchaseAt))")

		// T27 — PM-03 row 20, the case that keeps row 19 from overshooting: once the old mark has
		// aged out, a genuinely new purchase opens its own window rather than inheriting a deadline
		// that has already passed.
		let t27 = PremiumResolver.resolve(adapty: PremiumAccess(isActive: false), apple: nil, cached: markedPremium(now - 8 * day), localPurchase: true, now: now)
		check(t27.isPremium == true, "PM-03 row 20: a new purchase after the old mark aged out must still be protected — expected isPremium true, got \(t27.isPremium)")
		check(t27.localPurchaseAt == now, "PM-03 row 20: the new purchase starts its own window, expected \(now), got \(String(describing: t27.localPurchaseAt))")

		// MARK: - Part B: PremiumService, with mocks.

		// T13 — PM-04 row 9: Adapty asks for the StoreKit fallback and the fallback purchase
		// succeeds — the resulting state must carry the local-purchase mark.
		let t13Store = SpyStore()
		let t13Adapty = FakeAdapty(answer: nil)
		t13Adapty.buyResult = .retryWithStoreKit
		let t13Apple = FakeApple(receipt: nil)
		t13Apple.purchaseResult = .purchased
		let t13Service = PremiumService(store: t13Store, adapty: t13Adapty, apple: t13Apple, levels: ["premium"], sourceTimeout: 1)
		var t13Outcome: PurchaseOutcome?
		t13Service.purchase("year.sub", placement: "main") { t13Outcome = $0 }
		check(wait { t13Outcome != nil }, "PM-04 row 9: purchase must call back")
		check(t13Store.cached?.localPurchase == true, "PM-04 row 9: a StoreKit-fallback purchase must mark localPurchase true, got \(String(describing: t13Store.cached?.localPurchase))")

		// T14 — PM-04 row 9, the negative: Adapty confirms the purchase itself — no mark needed,
		// the state is already verified through Adapty.
		let t14Store = SpyStore()
		let t14Adapty = FakeAdapty(answer: profile(active: true, expiresAt: now + hour))
		t14Adapty.buyResult = .success
		let t14Apple = FakeApple(receipt: nil)
		let t14Service = PremiumService(store: t14Store, adapty: t14Adapty, apple: t14Apple, levels: ["premium"], sourceTimeout: 1)
		var t14Outcome: PurchaseOutcome?
		t14Service.purchase("year.sub", placement: "main") { t14Outcome = $0 }
		check(wait { t14Outcome != nil }, "PM-04 row 9 (negative): purchase must call back")
		check(t14Store.cached?.localPurchase == false, "PM-04 row 9 (negative): a direct Adapty purchase must not carry the mark — expected localPurchase false, got \(String(describing: t14Store.cached?.localPurchase))")

		// T15 — PM-04 row 10: the StoreKit-fallback path must sync the receipt back to Adapty; a
		// purchase Adapty confirmed itself must not bother it. Reuses T13/T14's mocks — same
		// purchases, read after they already settled above.
		check(t13Adapty.syncReceiptCount == 1, "PM-04 row 10: a StoreKit-fallback purchase must call adapty.syncReceipt() once, got \(t13Adapty.syncReceiptCount)")
		check(t14Adapty.syncReceiptCount == 0, "PM-04 row 10: a direct Adapty purchase must not call syncReceipt(), got \(t14Adapty.syncReceiptCount)")

		// T16 — PM-05 row 8: a StoreKit restore must mark localPurchase the same way a purchase
		// does; nothing to restore must not.
		let t16RestoredStore = SpyStore()
		let t16RestoredApple = FakeApple(receipt: nil)
		t16RestoredApple.restoreResult = .restored
		let t16RestoredService = PremiumService(store: t16RestoredStore, adapty: nil, apple: t16RestoredApple, levels: ["premium"], sourceTimeout: 1)
		var t16RestoredOutcome: RestoreOutcome?
		t16RestoredService.restore { t16RestoredOutcome = $0 }
		check(wait { t16RestoredOutcome != nil }, "PM-05 row 8: restore must call back")
		check(t16RestoredStore.cached?.localPurchase == true, "PM-05 row 8: a restored purchase must mark localPurchase true, got \(String(describing: t16RestoredStore.cached?.localPurchase))")

		let t16EmptyStore = SpyStore()
		let t16EmptyApple = FakeApple(receipt: nil)
		t16EmptyApple.restoreResult = .nothingToRestore
		let t16EmptyService = PremiumService(store: t16EmptyStore, adapty: nil, apple: t16EmptyApple, levels: ["premium"], sourceTimeout: 1)
		var t16EmptyOutcome: RestoreOutcome?
		t16EmptyService.restore { t16EmptyOutcome = $0 }
		check(wait { t16EmptyOutcome != nil }, "PM-05 row 8: restore must call back")
		check(t16EmptyStore.cached?.localPurchase == false, "PM-05 row 8: nothing to restore must not mark localPurchase — expected false, got \(String(describing: t16EmptyStore.cached?.localPurchase))")

		// T17 — PM-08 row 7: a purchase delivered from the payment queue must mark localPurchase too.
		let t17Store = SpyStore()
		let t17Service = PremiumService(store: t17Store, adapty: nil, apple: nil, levels: ["premium"], sourceTimeout: 1)
		t17Service.purchaseDelivered()
		check(wait { t17Store.cached != nil }, "PM-08 row 7: purchaseDelivered() must produce a verdict")
		check(t17Store.cached?.localPurchase == true, "PM-08 row 7: a delivered purchase must mark localPurchase true, got \(String(describing: t17Store.cached?.localPurchase))")

		// T18/T19 share the same starting cache: a state the local-purchase mark is holding up,
		// pushed at through the public, synchronous `apply(adapty:)` entry point instead of the
		// pure resolver — the same scenarios as T1/T2, but through the real delegate-push path.
		let pushCache = PremiumState(isPremium: true, source: .apple, isVerified: false, expiresAt: nil, localPurchase: true)

		// T18 — an inactive Adapty push must not revoke a state the mark is holding up.
		let t18Store = SpyStore(cached: pushCache, premium: true)
		let t18Service = PremiumService(store: t18Store, adapty: nil, apple: nil, levels: ["premium"], sourceTimeout: 1)
		t18Service.apply(adapty: PremiumAccess(isActive: false))
		check(t18Service.isPremium == true, "PM-03 row 10 (via apply(adapty:)): an inactive Adapty push must not revoke a marked local purchase — expected isPremium true, got \(t18Service.isPremium)")

		// T19 — same starting cache, but Adapty confirms: isPremium holds, and the mark must drop.
		let t19Store = SpyStore(cached: pushCache, premium: true)
		let t19Service = PremiumService(store: t19Store, adapty: nil, apple: nil, levels: ["premium"], sourceTimeout: 1)
		t19Service.apply(adapty: PremiumAccess(isActive: true, expiresAt: now + hour))
		check(t19Service.isPremium == true, "PM-03 row 11 (via apply(adapty:)): expected isPremium true, got \(t19Service.isPremium)")
		check(t19Store.cached?.localPurchase == false, "PM-03 row 11 (via apply(adapty:)): Adapty confirmed — expected the mark to drop, localPurchase false, got \(String(describing: t19Store.cached?.localPurchase))")

		// T20 — PM-07 row 9: Adapty's placement listing came back empty, but the service still
		// knows its own productIds — the fallback should ask Apple directly and hand back priced
		// products for them.
		let t20Adapty = FakeAdapty(answer: nil)
		let t20Apple = FakeApple(receipt: nil)
		t20Apple.catalogue = [
			"a": PremiumProduct(id: "a", localizedTitle: "A", localizedPrice: "$1.99", price: 1.99, currencyCode: "USD", subscriptionPeriod: nil, introductoryOffer: nil),
			"b": PremiumProduct(id: "b", localizedTitle: "B", localizedPrice: "$2.99", price: 2.99, currencyCode: "USD", subscriptionPeriod: nil, introductoryOffer: nil),
		]
		let t20Service = PremiumService(store: SpyStore(), adapty: t20Adapty, apple: t20Apple, levels: ["premium"], sourceTimeout: 1, productIds: ["a", "b"])
		var t20Result: [PremiumProduct]?
		t20Service.products(placement: "main") { t20Result = $0 }
		check(wait { t20Result != nil }, "PM-07 row 9: products(placement:) must call back")
		check(t20Result?.count == 2, "PM-07 row 9: an empty Adapty placement must fall back to productIds — expected exactly 2 products, got \(t20Result?.count ?? -1)")
		check(t20Result?.first(where: { $0.id == "a" })?.localizedPrice == "$1.99", "PM-07 row 9: expected product 'a' priced at the store's $1.99, got \(String(describing: t20Result?.first(where: { $0.id == "a" })?.localizedPrice))")
		check(t20Result?.first(where: { $0.id == "b" })?.localizedPrice == "$2.99", "PM-07 row 9: expected product 'b' priced at the store's $2.99, got \(String(describing: t20Result?.first(where: { $0.id == "b" })?.localizedPrice))")

		if failures.isEmpty {
			print("PremiumService local-purchase mark (PM-03/04/05/07/08): 27/27 OK")
		} else {
			print("\(failures.count) check(s) failed:")
			for failure in failures {
				print("  - \(failure)")
			}
			exit(1)
		}
	}
}

// Appended rather than declared inside `FakeAdapty`: the PM-03/04/05/07/08 risk tables quote line
// numbers in this file, and a member added up there moves every one of them. This fake stands for a
// layer that came up — the rows here are about the local-purchase mark, not about activation.
extension FakeAdapty {
	var isActive: Bool { true }
}

// PM-04 row 14 added `setProfileValue` to `AdaptyPremiumProviding`. Nothing here reads it — the
// placement write is asserted in `PremiumBarrierCheck` case 33 — so this is conformance only, and
// it is appended rather than folded into the fake so no quoted line number moves.
extension FakeAdapty {
	func setProfileValue(value: String, key: String) {}
}
