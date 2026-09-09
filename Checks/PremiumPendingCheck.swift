//
//  PremiumPendingCheck.swift
//  IntegrationKit
//
//  Pins down two behaviours from `PremiumService`'s risk table — PM-01 row 4 (an idempotency guard on
//  `start()`) and PM-04 row 7 (a guard against concurrent `purchase()` calls). Both assertions encode
//  the DESIRED behaviour per the explicit decisions of 2026-09-08 ("гард обовʼязковий" and "блокуємо в
//  пакеті").
//
//  Written red, green since both guards landed in `Sources/PremiumService.swift`: a clean run is now
//  the expected outcome, and a failure here means one of the two guards was lost.
//
//  A third `немає` row is deliberately NOT here: PM-07 row 8 (no "paywalls are loaded" signal exists
//  anywhere on the public surface). There is no method to call — neither `PremiumServicing` nor
//  `AdaptyPremiumProviding` carries one — so even a red test would first have to add that method in
//  `Sources/`, which is out of scope for a check. It stays an open gap in the risk table instead.
//
//  Nothing here traps: like `PremiumStoreKitCheck`, every case runs, every failure is collected, and
//  the summary at the end reports all of them with a non-zero exit code. A crashing `assert` would
//  stop at case 1 and case 2 would never run.
//  Run:  ./Checks/premium-pending-check.sh
//

import Adapty
import Foundation

/// The smallest `PremiumStateStoring` that works. Neither case here reads the store — both count what
/// the Adapty side was asked to do — so there is nothing to spy on.
final class MemoryStore: PremiumStateStoring {
	private let lock = NSLock()
	private var state: PremiumState?
	private var flag = false

	var cached: PremiumState? {
		get {
			lock.lock()
			defer { lock.unlock() }
			return state
		}
		set {
			lock.lock()
			defer { lock.unlock() }
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
			flag = newValue
		}
	}
}

/// An Adapty that counts what it was asked for. `profile()` and `buy()` are called from the
/// cooperative pool, so the counters go behind a lock.
final class CountingAdapty: AdaptyPremiumProviding {
	private let lock = NSLock()
	private var profileCallCount = 0
	private var buyCallCount = 0
	private var observerAssignmentCount = 0

	var premiumObserver: ((AdaptyProfile, Bool) -> Void)? {
		didSet {
			lock.lock()
			observerAssignmentCount += 1
			lock.unlock()
		}
	}
	var answer: AdaptyProfile?
	var buyResult: AdaptyPurchaseResult = .success
	/// How long `buy` takes to come back — case 2 needs the first purchase still in flight when the
	/// second one is fired.
	var buyDelay: TimeInterval = 0

	var profileCalls: Int {
		lock.lock()
		defer { lock.unlock() }
		return profileCallCount
	}

	var buyCalls: Int {
		lock.lock()
		defer { lock.unlock() }
		return buyCallCount
	}

	var observerAssignments: Int {
		lock.lock()
		defer { lock.unlock() }
		return observerAssignmentCount
	}

	/// The counting itself stays in synchronous helpers: `NSLock` is `noasync`, and case 2 fires two
	/// `buy` calls at once, so an unlocked `+= 1` could under-count and hand this script a green run
	/// it did not earn.
	private func countProfileCall() {
		lock.lock()
		profileCallCount += 1
		lock.unlock()
	}

	private func countBuyCall() {
		lock.lock()
		buyCallCount += 1
		lock.unlock()
	}

	func profile() async -> AdaptyProfile? {
		countProfileCall()
		return answer
	}

	func buy(productId: String, placement: String) async -> AdaptyPurchaseResult {
		countBuyCall()
		if buyDelay > 0 {
			try? await Task.sleep(nanoseconds: UInt64(buyDelay * 1_000_000_000))
		}
		return buyResult
	}

	func products(placement: String) async -> AdaptyProductsAnswer { .notReady }
	func remoteValue<T>(placement: String, key: String) -> RemoteValue<T> { .notReady }
	func logPaywallOpen(placement: String) {}
	func hasPaywall(placement: String) -> Bool { false }
	func paywallState(placement: String) -> PaywallState { .unavailable }
	func syncReceipt() {}
}

@main
enum PremiumPendingCheck {
	static var failures: [String] = []

	/// Records a failure instead of trapping — case 1 failing must not stop case 2 from running.
	static func check(_ condition: @autoclosure () -> Bool, _ message: @autoclosure () -> String) {
		guard !condition() else { return }
		let text = message()
		failures.append(text)
		print("FAILED: \(text)")
	}

	/// Polls instead of awaiting, same as the green checks: `refresh()` is fire-and-forget, and
	/// `purchase`'s completion comes back on the main queue.
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
		// 1. PM-01 row 4 — an app that calls `start()` itself on top of the composition root calls it
		//    twice. Decision 2026-09-08: the second call must be a no-op. Without the guard the second
		//    `start()` installs a second push observer AND fires a second full refresh — a redundant
		//    round trip to Adapty and a second recompute of a state nothing changed.
		let startStore = MemoryStore()
		let startAdapty = CountingAdapty()
		let startService = PremiumService(store: startStore, adapty: startAdapty, apple: nil, levels: ["premium"], sourceTimeout: 1)
		startService.start()
		startService.start()
		// Returns as soon as a second fetch shows up; times out (and leaves the count at 1) once the
		// guard exists.
		wait(0.5) { startAdapty.profileCalls >= 2 }
		check(
			startAdapty.profileCalls == 1,
			"case 1 (PM-01 row 4): start() twice must do the work exactly once — expected 1 Adapty profile fetch, got \(startAdapty.profileCalls); the push observer was installed \(startAdapty.observerAssignments) time(s), expected 1. The idempotency guard decided on 2026-09-08 is not implemented yet"
		)

		// 2. PM-04 row 7 — two `purchase()` calls fired without awaiting the first. Decision
		//    2026-09-08: the second must be rejected in-package with `.failed` so the user is never
		//    shown two payment dialogs. Without the guard each call spawns its own `Task` and both
		//    reach the SDK. `buyDelay` keeps the first purchase in flight while the second fires.
		let buyStore = MemoryStore()
		let buyAdapty = CountingAdapty()
		buyAdapty.buyResult = .success
		buyAdapty.buyDelay = 0.3
		let buyService = PremiumService(store: buyStore, adapty: buyAdapty, apple: nil, levels: ["premium"], sourceTimeout: 1)
		var completions = 0
		buyService.purchase("year.sub", placement: "main") { _ in completions += 1 }
		buyService.purchase("year.sub", placement: "main") { _ in completions += 1 }
		wait(2) { completions >= 2 }
		check(
			buyAdapty.buyCalls == 1,
			"case 2 (PM-04 row 7): a second purchase() before the first settled must be rejected without reaching the SDK — expected exactly 1 buy attempt, got \(buyAdapty.buyCalls) for \(completions) completed purchase() call(s). The concurrency guard decided on 2026-09-08 is not implemented yet"
		)

		if failures.isEmpty {
			print("PremiumService guards (PM-01 row 4, PM-04 row 7): 2/2 OK")
		} else {
			print("\(failures.count) check(s) failed:")
			for failure in failures {
				print("  - \(failure)")
			}
			exit(1)
		}
	}
}
