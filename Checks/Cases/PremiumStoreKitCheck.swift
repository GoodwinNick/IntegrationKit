//
//  PremiumStoreKitCheck.swift
//  IntegrationKit
//
//  PM-05 rows 1-5 (restore) — spec section 6 — through the `PremiumService` facade with a mocked
//  `AppleSubscribing`, same pattern as `PremiumBarrierCheck`.
//
//  Rewritten 2026-09-16 for Asana 1218522745188504 (StoreKit 2, SwiftyStoreKit gone): rows 6-7 and
//  PM-07 row 5 used to exercise the REAL `StoreKitService` against a stubbed `SwiftyStoreKit` — that
//  seam does not exist anymore. `Product`/`Transaction` are sealed StoreKit 2 types with no public
//  initializer, so nothing in this harness can hand `StoreKitService` a controlled Apple answer.
//  PM-05 row 6 (empty `sharedSecret`) is gone outright — `configure()` no longer takes one at all.
//  PM-05 row 7 (mixed restored/failed results) described a shape `SwiftyStoreKit.RestoreResults` had
//  and `Transaction.currentEntitlements` does not: StoreKit 2's restore reads one list of current
//  entitlements, not a restored/failed pair, so there is nothing left to reduce. PM-07 row 5 (StoreKit
//  answering nothing) stays documented as untested in the PM-07 risk table.
//  Run:  ./Checks/premium-storekit-check.sh
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

/// An Adapty that answers whatever it is told — trimmed to what PM-05 rows 2 and 5 read.
final class FakeAdapty: AdaptyPremiumProviding {
	var premiumObserver: ((AdaptyProfile, Bool) -> Void)?
	var answer: AdaptyProfile?

	init(answer: AdaptyProfile?) {
		self.answer = answer
	}

	func profile() async -> AdaptyProfile? { answer }
	func products(placement: String) async -> AdaptyProductsAnswer { .notReady }
	func buy(productId: String, placement: String) async -> PurchaseVerdict { .failed }
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

		if failures.isEmpty {
			print("PremiumService restore (PM-05 rows 1-5): 12/12 OK")
		} else {
			print("\(failures.count) check(s) failed:")
			for failure in failures {
				print("  - \(failure)")
			}
			exit(1)
		}
	}
}

// Appended rather than declared inside `FakeAdapty`, so the line numbers PM-05 quotes in this file
// do not move. A layer that came up: these rows are about restore through the facade, not activation.
extension FakeAdapty {
	var isActive: Bool { true }
	func setProfileValue(value: String, key: String) {}
}
