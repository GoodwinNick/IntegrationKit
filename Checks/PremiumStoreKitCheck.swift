//
//  PremiumStoreKitCheck.swift
//  IntegrationKit
//
//  PM-05 (restore) and PM-08 (unfinished transactions) — spec section 6 — plus PM-07 row 5, which
//  needs the real `StoreKitService` and so lives here rather than in the barrier check. PM-05 rows
//  1-5 go through the `PremiumService` facade with a mocked `AppleSubscribing`, same as
//  `PremiumBarrierCheck`; rows 6-7, PM-07 row 5 and all of PM-08 exercise the real `StoreKitService`
//  against a stubbed `SwiftyStoreKit`.
//
//  This check does not stop at the first failing row: every row runs, every failure is collected, and
//  the summary at the end reports all of them with a non-zero exit code.
//  Run:  ./Checks/premium-storekit-check.sh
//

import Adapty
import Foundation
import StoreKit
import SwiftyStoreKit

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

/// An Adapty that answers whatever it is told — trimmed to what PM-05 rows 2 and 5 read.
final class FakeAdapty: AdaptyPremiumProviding {
	var premiumObserver: ((AdaptyProfile, Bool) -> Void)?
	var answer: AdaptyProfile?

	init(answer: AdaptyProfile?) {
		self.answer = answer
	}

	func profile() async -> AdaptyProfile? { answer }
	func products(placement: String) async -> AdaptyProductsAnswer { .notReady }
	func buy(productId: String, placement: String) async -> AdaptyPurchaseResult { .failed }
	func remoteValue<T>(placement: String, key: String) -> RemoteValue<T> { .notReady }
	func logPaywallOpen(placement: String) {}
	func hasPaywall(placement: String) -> Bool { false }
	func paywallState(placement: String) -> PaywallState { .unavailable }
	func syncReceipt() {}
}

/// The Apple side, same idea. `restoreDelay` is new here — none of the barrier check's cases needed
/// a slow `restore()`, but PM-05 rows 1 and 4 do.
final class FakeApple: AppleSubscribing {
	var receipt: ReceiptAnswer?
	var restoreResult: RestoreOutcome = .nothingToRestore
	var restoreDelay: TimeInterval = 0

	init(receipt: ReceiptAnswer?) {
		self.receipt = receipt
	}

	func checkReceipt() async -> ReceiptAnswer? { receipt }

	func restore() async -> RestoreOutcome {
		if restoreDelay > 0 {
			try? await Task.sleep(nanoseconds: UInt64(restoreDelay * 1_000_000_000))
		}
		return restoreResult
	}

	func purchase(productId: String) async -> PurchaseOutcome { .failed }
	func products(ids: Set<String>) async -> [String: PremiumProduct] { [:] }
}

@main
enum PremiumStoreKitCheck {
	static let hour: TimeInterval = 3600
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

	/// Polls instead of awaiting, same as `PremiumBarrierCheck`: `refresh()` is fire-and-forget, and
	/// `restore`'s completion comes back on the main queue.
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

		// PM-05 row 1: `PremiumService.swift:194-195` awaits the restore, resolves both sources, and
		// only THEN schedules the completion — by the time the caller's completion runs, the store
		// already carries the new verdict, nothing left to chase.
		let orderingStore = SpyStore()
		let orderingApple = FakeApple(receipt: nil)
		orderingApple.restoreResult = .restored
		orderingApple.restoreDelay = 0.2
		let orderingService = PremiumService(store: orderingStore, adapty: nil, apple: orderingApple, levels: ["premium"], sourceTimeout: 1)
		var writesInsideCompletion = -1
		orderingService.restore { _ in writesInsideCompletion = orderingStore.writes }
		check(wait { writesInsideCompletion >= 0 }, "PM-05 row 1: restore must call back")
		check(writesInsideCompletion > 0, "PM-05 row 1: store.writes must already be > 0 inside the completion, got \(writesInsideCompletion)")

		// PM-05 row 2: nothing to restore, and both sources already agree with what is cached — the
		// barrier must not write or notify for an answer that changes nothing.
		let matchedExpiry = now + hour
		let matchedCached = PremiumState(isPremium: true, source: .adapty, isVerified: true, expiresAt: matchedExpiry)
		let matchedStore = SpyStore(cached: matchedCached, premium: true)
		let matchedAdapty = FakeAdapty(answer: profile(active: true, expiresAt: matchedExpiry))
		let matchedApple = FakeApple(receipt: ReceiptAnswer(isActive: true, expiresAt: nil))
		matchedApple.restoreResult = .nothingToRestore
		let matchedService = PremiumService(store: matchedStore, adapty: matchedAdapty, apple: matchedApple, levels: ["premium"], sourceTimeout: 1)
		var matchedOutcome: RestoreOutcome?
		matchedService.restore { matchedOutcome = $0 }
		check(wait { matchedOutcome != nil }, "PM-05 row 2: restore must call back")
		check(matchedOutcome == .nothingToRestore, "PM-05 row 2: the mock reported nothing to restore, got \(String(describing: matchedOutcome))")
		check(matchedStore.writes == 0, "PM-05 row 2: both sources matched the cache — zero writes, got \(matchedStore.writes)")
		check(matchedStore.notified == 0, "PM-05 row 2: both sources matched the cache — zero notifications, got \(matchedStore.notified)")

		// PM-05 row 3: no Apple source at all — `restore` fails immediately, no timeout involved.
		let noAppleStore = SpyStore()
		let noAppleService = PremiumService(store: noAppleStore, adapty: nil, apple: nil, levels: ["premium"], sourceTimeout: 1)
		var noAppleOutcome: RestoreOutcome?
		let noAppleStarted = Date()
		noAppleService.restore { noAppleOutcome = $0 }
		check(wait(0.3) { noAppleOutcome != nil }, "PM-05 row 3: restore must call back")
		let noAppleElapsed = Date().timeIntervalSince(noAppleStarted)
		check(noAppleOutcome == .failed, "PM-05 row 3: no Apple source must fail, got \(String(describing: noAppleOutcome))")
		check(noAppleElapsed < 0.3, "PM-05 row 3: must arrive without waiting for the timeout, took \(noAppleElapsed)s")

		// PM-05 row 4: `restore` has no timeout of its own (PremiumService.swift:190-193) — a
		// StoreKit restore that never resolves must simply never call back. Documents that choice.
		let stuckStore = SpyStore()
		let stuckApple = FakeApple(receipt: nil)
		stuckApple.restoreDelay = 10
		let stuckService = PremiumService(store: stuckStore, adapty: nil, apple: stuckApple, levels: ["premium"], sourceTimeout: 1)
		var stuckOutcome: RestoreOutcome?
		stuckService.restore { stuckOutcome = $0 }
		check(!wait(0.5) { stuckOutcome != nil }, "PM-05 row 4: a restore that never resolves must not call back within 0.5s, got \(String(describing: stuckOutcome))")

		// PM-05 row 5: Adapty active still wins outright over a restore (PremiumResolver step 1).
		// An inactive answer arriving in the same round no longer does: a restore that just landed
		// carries its own mark, same as PM-03 row 10, and Adapty has not confirmed THIS restore yet.
		let overriddenStore = SpyStore()
		let overriddenAdapty = FakeAdapty(answer: profile(active: false))
		let overriddenApple = FakeApple(receipt: nil)
		overriddenApple.restoreResult = .restored
		let overriddenService = PremiumService(store: overriddenStore, adapty: overriddenAdapty, apple: overriddenApple, levels: ["premium"], sourceTimeout: 1)
		var overriddenOutcome: RestoreOutcome?
		overriddenService.restore { overriddenOutcome = $0 }
		check(wait { overriddenOutcome != nil }, "PM-05 row 5: restore must call back")
		check(overriddenService.isPremium == true, "PM-05 row 5: a fresh restore's mark must hold against an inactive Adapty answer in the same round, got isPremium == \(overriddenService.isPremium)")

		// PM-05 row 6: an empty shared secret means receipt validation was never configured —
		// `checkReceipt` answers nil without ever reaching the network.
		SwiftyStoreKit.reset()
		let blankSecretService = StoreKitService(sharedSecret: "", productIds: ["a"])
		var blankSecretReceipt: ReceiptAnswer??
		Task { blankSecretReceipt = await blankSecretService.checkReceipt() }
		check(wait { blankSecretReceipt != nil }, "PM-05 row 6: checkReceipt must call back")
		check(blankSecretReceipt! == nil, "PM-05 row 6: an empty sharedSecret must answer nil, got \(String(describing: blankSecretReceipt!))")
		check(SwiftyStoreKit.verifyReceiptCallCount == 0, "PM-05 row 6: no network call — verifyReceipt must be called 0 times, got \(SwiftyStoreKit.verifyReceiptCallCount)")

		// PM-05 row 7: something restored AND something failed — a restore is still a restore.
		SwiftyStoreKit.reset()
		let mixedTransaction = StubTransaction(state: .restored, label: "row7")
		SwiftyStoreKit.restorePurchasesResult = RestoreResults(
			restoredPurchases: [Purchase(transaction: mixedTransaction, productId: "year.sub", needsFinishTransaction: true)],
			restoreFailedPurchases: ["month.sub"]
		)
		let mixedService = StoreKitService(sharedSecret: "shared-secret", productIds: ["year.sub"])
		var mixedOutcome: RestoreOutcome?
		Task { mixedOutcome = await mixedService.restore() }
		check(wait { mixedOutcome != nil }, "PM-05 row 7: restore must call back")
		check(mixedOutcome == .restored, "PM-05 row 7: restored+failed together must resolve to .restored, got \(String(describing: mixedOutcome))")

		// PM-07 row 5: StoreKit did not answer at all (no network when the paywall opened). The error
		// is logged and the request resolves with an EMPTY dictionary — never an exception, never a
		// fabricated zero price. There is no Adapty fallback down here on purpose: that merge lives one
		// layer up, in `PremiumService.products(placement:)`, so `StoreKitService` must answer `[:]`.
		SwiftyStoreKit.reset()
		SwiftyStoreKit.retrieveProductsInfoResult = RetrieveResults(retrievedProducts: [], invalidProductIDs: ["year.sub"], error: URLError(.notConnectedToInternet))
		let offlinePricesService = StoreKitService(sharedSecret: "", productIds: ["year.sub"])
		var offlinePrices: [String: PremiumProduct]?
		Task { offlinePrices = await offlinePricesService.products(ids: ["year.sub", "week.sub"]) }
		check(wait { offlinePrices != nil }, "PM-07 row 5: products(ids:) must call back")
		check(offlinePrices == [:], "PM-07 row 5: a store that answered nothing must give exactly [:], got \(String(describing: offlinePrices))")

		// PM-08 row 1: one purchased transaction in the queue — finished exactly once, delivered
		// exactly once.
		SwiftyStoreKit.reset()
		let singleDeliveryTransaction = StubTransaction(state: .purchased, label: "row1")
		SwiftyStoreKit.completeTransactionsResult = [Purchase(transaction: singleDeliveryTransaction, productId: "year.sub", needsFinishTransaction: true)]
		let singleDeliveryService = StoreKitService(sharedSecret: "", productIds: ["year.sub"])
		var singleDeliveryCount = 0
		singleDeliveryService.completeTransactions { singleDeliveryCount += 1 }
		check(SwiftyStoreKit.finishTransactionCalls.count == 1, "PM-08 row 1: exactly one finish, got \(SwiftyStoreKit.finishTransactionCalls.count)")
		check(singleDeliveryCount == 1, "PM-08 row 1: onDelivered must fire exactly once, got \(singleDeliveryCount)")

		// PM-08 row 2: order, not just fact — `onDelivered` must see the transaction already
		// finished, not the other way around.
		SwiftyStoreKit.reset()
		let orderedDeliveryTransaction = StubTransaction(state: .purchased, label: "row2")
		SwiftyStoreKit.completeTransactionsResult = [Purchase(transaction: orderedDeliveryTransaction, productId: "year.sub", needsFinishTransaction: true)]
		let orderedDeliveryService = StoreKitService(sharedSecret: "", productIds: ["year.sub"])
		var finishCountAtDelivery = -1
		orderedDeliveryService.completeTransactions { finishCountAtDelivery = SwiftyStoreKit.finishTransactionCalls.count }
		check(finishCountAtDelivery == 1, "PM-08 row 2: finishTransaction must run before onDelivered, saw \(finishCountAtDelivery) finished call(s) inside onDelivered")

		// PM-08 row 4: a transaction in the `.failed` state. Our own loop takes the
		// `case .failed, .purchasing, .deferred: break` branch — it neither finishes it nor counts it
		// as delivered, so nothing about it can turn premium on. (Closing failed transactions is the
		// library's job, unconditionally and before our callback; what is pinned here is that WE do
		// not touch it.)
		SwiftyStoreKit.reset()
		let failedTransaction = StubTransaction(state: .failed, label: "row4")
		SwiftyStoreKit.completeTransactionsResult = [Purchase(transaction: failedTransaction, productId: "year.sub", needsFinishTransaction: true)]
		let failedQueueService = StoreKitService(sharedSecret: "", productIds: ["year.sub"])
		var failedQueueDeliveries = 0
		failedQueueService.completeTransactions { failedQueueDeliveries += 1 }
		let failedQueueFinished = SwiftyStoreKit.finishTransactionCalls.compactMap { ($0 as? StubTransaction)?.label }
		check(failedQueueFinished == [], "PM-08 row 4: a failed transaction must not be finished by our code — expected finishTransaction calls [], got \(failedQueueFinished)")
		check(failedQueueDeliveries == 0, "PM-08 row 4: a failed transaction is not a delivery — expected onDelivered called 0 times, got \(failedQueueDeliveries)")

		// PM-08, the empty-queue check from the risk table's "how to reproduce" — NOT row 6. Row 6 is
		// the three-way race between the queue, the profile push and `start()`'s refresh, and it needs
		// two competing writers, which only the facade check has: `premium-barrier-check.sh` cases 14
		// and 23 own it. What is pinned here is the boring half nobody would otherwise write down —
		// a queue with nothing in it finishes nothing and delivers nothing.
		SwiftyStoreKit.reset()
		let emptyQueueService = StoreKitService(sharedSecret: "", productIds: ["year.sub"])
		var emptyQueueCount = 0
		emptyQueueService.completeTransactions { emptyQueueCount += 1 }
		check(SwiftyStoreKit.finishTransactionCalls.count == 0, "PM-08 empty queue: zero finishes, got \(SwiftyStoreKit.finishTransactionCalls.count)")
		check(emptyQueueCount == 0, "PM-08 empty queue: onDelivered must not fire, got \(emptyQueueCount)")

		// PM-08 row 5: a purchase lands in the queue, Adapty stays silent, and the receipt still says
		// "no" (the App Store has not caught up yet) — the delivered purchase itself has to be enough.
		// The composition root (`IntegrationKit.swift`) wires the delivery to `purchaseDelivered()`,
		// which resolves with the just-purchased mark; wired the same way here, so this row exercises
		// the call the real root makes.
		SwiftyStoreKit.reset()
		let wiredTransaction = StubTransaction(state: .purchased, label: "row5")
		SwiftyStoreKit.completeTransactionsResult = [Purchase(transaction: wiredTransaction, productId: "year.sub", needsFinishTransaction: true)]
		SwiftyStoreKit.verifyReceiptResult = .success([:])
		SwiftyStoreKit.verifySubscriptionResult = .notPurchased
		let wiredStoreKit = StoreKitService(sharedSecret: "shared-secret", productIds: ["year.sub"])
		let wiredStore = SpyStore()
		let wiredPremium = PremiumService(store: wiredStore, adapty: nil, apple: wiredStoreKit, levels: ["premium"], sourceTimeout: 1)
		wiredStoreKit.completeTransactions { [weak wiredPremium] in wiredPremium?.purchaseDelivered() }
		check(wait { wiredStore.writes > 0 }, "PM-08 row 5: refresh after a delivered purchase must produce a verdict")
		check(SwiftyStoreKit.verifyReceiptCallCount == 1, "PM-08 row 5: the receipt must actually be checked, not just left unchecked — verifyReceipt call count got \(SwiftyStoreKit.verifyReceiptCallCount)")
		check(wiredPremium.isPremium == true, "PM-08 row 5: a purchase delivered from the queue must grant premium even when the receipt says no, got isPremium == \(wiredPremium.isPremium)")

		// PM-08 row 5, the combination the receipt alone can never win: the same delivered purchase,
		// but the cache already holds a verified "no premium" from an earlier launch and Adapty is
		// silent now. Resolver step 2 would hand that cache straight back; `purchaseDelivered()` demotes
		// the copy to `isVerified: false` for this one resolve, so step 2 stops matching and step 3 wins.
		SwiftyStoreKit.reset()
		let cachedNoTransaction = StubTransaction(state: .purchased, label: "row5-cached-no")
		SwiftyStoreKit.completeTransactionsResult = [Purchase(transaction: cachedNoTransaction, productId: "year.sub", needsFinishTransaction: true)]
		SwiftyStoreKit.verifyReceiptResult = .success([:])
		SwiftyStoreKit.verifySubscriptionResult = .notPurchased
		let cachedNoStoreKit = StoreKitService(sharedSecret: "shared-secret", productIds: ["year.sub"])
		let cachedNoStore = SpyStore(cached: PremiumState(isPremium: false, source: .adapty, isVerified: true))
		let cachedNoService = PremiumService(store: cachedNoStore, adapty: nil, apple: cachedNoStoreKit, levels: ["premium"], sourceTimeout: 1)
		cachedNoStoreKit.completeTransactions { [weak cachedNoService] in cachedNoService?.purchaseDelivered() }
		check(wait { cachedNoStore.writes > 0 }, "PM-08 row 5: a delivered purchase must produce a verdict over a cached verified no")
		check(cachedNoService.isPremium == true, "PM-08 row 5: a delivered purchase must outrank a cached verified 'no premium' while Adapty stays silent, got isPremium == \(cachedNoService.isPremium)")

		// PM-08 row 10: the queue is read on every launch and `completeTransactions` runs
		// unconditionally, so a delivery that changes nothing must cost nothing. The user whose premium
		// is already on, held up by the mark from a previous launch, is the common case — the resolve
		// lands on the very state that is cached, so there is nothing to write and nothing to announce.
		SwiftyStoreKit.reset()
		let markedTransaction = StubTransaction(state: .purchased, label: "row10-marked")
		SwiftyStoreKit.completeTransactionsResult = [Purchase(transaction: markedTransaction, productId: "year.sub", needsFinishTransaction: true)]
		// A real shared secret on purpose: `verifyReceiptCallCount` is then the discriminator. Zero
		// writes proves nothing on its own — it is exactly what a delivery that never arrived would
		// look like too — so the row also pins that the resolve ran all the way out to the receipt.
		let markedStoreKit = StoreKitService(sharedSecret: "shared-secret", productIds: ["year.sub"])
		let markedStore = SpyStore(cached: PremiumState(isPremium: true, source: .apple, isVerified: false, expiresAt: nil, localPurchase: true), premium: true)
		let markedService = PremiumService(store: markedStore, adapty: nil, apple: markedStoreKit, levels: ["premium"], sourceTimeout: 1)
		markedStoreKit.completeTransactions { [weak markedService] in markedService?.purchaseDelivered() }
		check(wait { SwiftyStoreKit.verifyReceiptCallCount == 1 }, "PM-08 row 10: the delivery must actually reach a resolve — expected the receipt to be checked once, got \(SwiftyStoreKit.verifyReceiptCallCount)")
		check(!wait(0.4) { markedStore.writes > 0 }, "PM-08 row 10: re-delivering a purchase the cache already carries must write nothing, got \(markedStore.writes) write(s)")
		check(markedStore.notified == 0, "PM-08 row 10: nothing changed — expected 0 .premiumDidChange, got \(markedStore.notified)")
		check(markedService.isPremium == true, "PM-08 row 10: premium must stay on across the re-delivery, got \(markedService.isPremium)")

		// PM-08 row 10, the half that does write: premium Adapty had already verified. The mark demotes
		// the cached copy for this one resolve (row 5's mechanism), so the state is rewritten as
		// unverified and marked — one disk write per launch, and nothing the user can see. The
		// notification is what must stay at zero: the flag never moved.
		SwiftyStoreKit.reset()
		let verifiedTransaction = StubTransaction(state: .purchased, label: "row10-verified")
		SwiftyStoreKit.completeTransactionsResult = [Purchase(transaction: verifiedTransaction, productId: "year.sub", needsFinishTransaction: true)]
		let verifiedStoreKit = StoreKitService(sharedSecret: "", productIds: ["year.sub"])
		let verifiedStore = SpyStore(cached: PremiumState(isPremium: true, source: .adapty, isVerified: true, expiresAt: now + hour), premium: true)
		let verifiedService = PremiumService(store: verifiedStore, adapty: nil, apple: verifiedStoreKit, levels: ["premium"], sourceTimeout: 1)
		verifiedStoreKit.completeTransactions { [weak verifiedService] in verifiedService?.purchaseDelivered() }
		check(wait { verifiedStore.writes > 0 }, "PM-08 row 10: the mark demotes the cached copy, so a verified premium is rewritten — expected a write")
		check(verifiedStore.notified == 0, "PM-08 row 10: the flag never moved — expected 0 .premiumDidChange, got \(verifiedStore.notified)")
		check(verifiedService.isPremium == true, "PM-08 row 10: a re-delivery must not disturb premium the user already has, got \(verifiedService.isPremium)")

		if failures.isEmpty {
			print("PremiumService restore (PM-05), prices (PM-07) and unfinished transactions (PM-08): 16/16 OK")
		} else {
			print("\(failures.count) check(s) failed:")
			for failure in failures {
				print("  - \(failure)")
			}
			exit(1)
		}
	}
}

// Appended rather than declared inside `FakeAdapty`, so the line numbers PM-05/07/08 quote in this
// file do not move. A layer that came up: these rows are about restore, prices and the payment
// queue, not about activation.
extension FakeAdapty {
	var isActive: Bool { true }
}
