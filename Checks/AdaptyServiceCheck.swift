//
//  AdaptyServiceCheck.swift
//  IntegrationKit
//
//  Covers PM-07 rows 8 and 10, and PM-04 row 8 — spec for behaviour `AdaptyService` does not
//  implement yet. T21/T22 stay red until `refreshPaywalls()` grows past the bare re-attempt this
//  task leaves it with: applying a successful retry, and retrying on its own until one succeeds,
//  are both the next task's job, on purpose. T25 stays red until `buyProduct` answers
//  `.retryWithStoreKit`, not `.failed`, for a product it never cached.
//  T23/T24 are already green: they pin the current, correct behaviour of `logPaywallOpen` so a
//  later change cannot loosen it silently.
//
//  This check does not stop at the first failing row: every row runs, every failure is collected,
//  and the summary at the end reports all of them with a non-zero exit code — same shape as
//  `PremiumLocalPurchaseCheck`. A non-zero exit here is the expected, healthy outcome until the
//  paywall retry and the StoreKit fallback are implemented.
//  Run:  ./Checks/adapty-service-check.sh
//

import Adapty
import AppTrackingTransparency
import Foundation

/// The only `AnalyticsTracking` `AdaptyService.configure` needs to run — nothing here is asserted
/// on by any row below.
final class FakeAnalytics: AnalyticsTracking {
	var deviceId: String? = "device-1"
	func configure(apiKey: String, deviceId: String, firstOpenEvent: String?) {}
	func logEvent(_ event: String, properties: [String: Any]?) {}
	func setUserProperties(_ properties: [String: Any]) {}
	func setUserId(_ userId: String) {}
	func updateTrackingAuthorization(_ status: ATTrackingManager.AuthorizationStatus) {}
}

@main
enum AdaptyServiceCheck {
	static var failures: [String] = []

	/// Records a failure instead of trapping — one failing row must not stop every row after it
	/// from running.
	static func check(_ condition: @autoclosure () -> Bool, _ message: @autoclosure () -> String) {
		guard !condition() else { return }
		let text = message()
		failures.append(text)
		print("FAILED: \(text)")
	}

	/// Polls instead of awaiting, same as the other checks — kept for the one row here
	/// (`buyProduct`) that answers through a completion instead of a plain return.
	@discardableResult
	static func wait(_ seconds: TimeInterval = 2, for condition: () -> Bool) -> Bool {
		let deadline = Date().addingTimeInterval(seconds)
		while Date() < deadline {
			if condition() { return true }
			RunLoop.current.run(until: Date().addingTimeInterval(0.005))
		}
		return condition()
	}

	/// `AdaptyPurchaseResult` carries no `Equatable` conformance (nothing in `Sources/` needs one),
	/// so T25 pattern-matches instead of adding one just for this check.
	static func isRetryWithStoreKit(_ result: AdaptyPurchaseResult?) -> Bool {
		if case .retryWithStoreKit = result { return true }
		return false
	}

	static func main() {
		// T21 — PM-07 row 8: `configure` runs with one placement whose first `getPaywall` fails.
		// The retry trigger then fires once, and the second queued answer succeeds. Expected:
		// hasPaywall(placement:) becomes true and exactly 2 calls were made. Actual: today's
		// `refreshPaywalls()` re-asks Adapty (call count does reach 2) but never applies a
		// successful answer, so hasPaywall stays false — RED.
		Adapty.reset()
		Adapty.getPaywallResults = [.failure(AdaptyError(.unknown)), .success(AdaptyPaywall())]
		let t21Service = AdaptyService()
		t21Service.configure(apiKey: "key", customerUserId: "u1", sessionsCounter: 1, placements: ["main"], analytics: FakeAnalytics())
		t21Service.refreshPaywalls()
		check(t21Service.hasPaywall(placement: "main") == true, "PM-07 row 8: after one retry trigger expected hasPaywall(placement:) true, got \(t21Service.hasPaywall(placement: "main"))")
		check(Adapty.getPaywallCallCount >= 2, "PM-07 row 8: after one retry trigger expected at least 2 getPaywall attempts, got \(Adapty.getPaywallCallCount)")

		// T22 — PM-07 row 8, the retry must continue on its own and must not spin. Every
		// `getPaywall` fails. The schema says loading continues until it succeeds — so after
		// `configure` the service keeps re-attempting by itself, spaced out, and again when the app
		// returns to the foreground. Both bounds come from that one sentence: a second attempt must
		// happen within a second WITHOUT any explicit trigger (RED today — nothing retries by
		// itself, so the count stays at 1), and the attempts must stay spaced, nowhere near a tight
		// loop. Counting explicit `refreshPaywalls()` calls would measure this check's own triggers
		// rather than the service's behaviour, so none are made here.
		Adapty.reset()
		Adapty.getPaywallResults = [.failure(AdaptyError(.unknown))]
		let t22Service = AdaptyService()
		t22Service.configure(apiKey: "key", customerUserId: "u1", sessionsCounter: 1, placements: ["main"], analytics: FakeAnalytics())
		wait(1) { Adapty.getPaywallCallCount >= 2 }
		let t22Count = Adapty.getPaywallCallCount
		check(t22Service.hasPaywall(placement: "main") == false, "PM-07 row 8: an always-failing placement must never report hasPaywall true, got \(t22Service.hasPaywall(placement: "main"))")
		check(t22Count >= 2, "PM-07 row 8: a failed load must retry on its own — expected at least 2 getPaywall attempts within a second of configure, got \(t22Count)")
		check(t22Count <= 5, "PM-07 row 8: the retry must stay spaced, never a tight loop — expected at most 5 getPaywall attempts in that second, got \(t22Count)")

		// T26 — PM-07 row 8, the retry must not stack. Every `getPaywall` fails, and the foreground
		// trigger fires three times on top of `configure`. Each of those four is one immediate
		// attempt, which is correct. What must NOT happen is four independent retry chains running
		// in parallel afterwards — a session that foregrounds twenty times would have twenty of
		// them hammering the SDK, the spin the backoff exists to prevent. So a second later at most
		// one further attempt has landed: 4 immediate + 1 chain, against the 8 that parallel chains
		// produce.
		Adapty.reset()
		Adapty.getPaywallResults = [.failure(AdaptyError(.unknown))]
		let t26Service = AdaptyService()
		t26Service.configure(apiKey: "key", customerUserId: "u1", sessionsCounter: 1, placements: ["main"], analytics: FakeAnalytics())
		t26Service.refreshPaywalls()
		t26Service.refreshPaywalls()
		t26Service.refreshPaywalls()
		let t26Immediate = Adapty.getPaywallCallCount
		check(t26Immediate == 4, "PM-07 row 8: configure plus three foreground triggers must each attempt once — expected 4 getPaywall attempts, got \(t26Immediate)")
		wait(1) { false }
		let t26Count = Adapty.getPaywallCallCount
		check(t26Count <= 6, "PM-07 row 8: retry chains must not stack per trigger — expected at most 6 getPaywall attempts a second after four triggers, got \(t26Count)")

		// T23 — PM-07 row 10: nothing was ever configured, so no paywall is loaded. Opening it must
		// not tell Adapty to log an impression for a paywall that was never shown. Already GREEN —
		// pins a recognised limit so it cannot regress silently.
		Adapty.reset()
		let t23Service = AdaptyService()
		t23Service.logPaywallOpen(placement: "main")
		check(Adapty.logShowPaywallCount == 0, "PM-07 row 10: no paywall loaded — expected logShowPaywallCount 0, got \(Adapty.logShowPaywallCount)")

		// T24 — PM-07 row 10, the positive: the placement's paywall IS loaded. Opening it must log
		// exactly one impression. Already GREEN.
		Adapty.reset()
		Adapty.getPaywallResults = [.success(AdaptyPaywall())]
		let t24Service = AdaptyService()
		t24Service.configure(apiKey: "key", customerUserId: "u1", sessionsCounter: 1, placements: ["main"], analytics: FakeAnalytics())
		check(t24Service.hasPaywall(placement: "main") == true, "PM-07 row 10 setup: expected the paywall to be loaded before logging, hasPaywall was false")
		t24Service.logPaywallOpen(placement: "main")
		check(Adapty.logShowPaywallCount == 1, "PM-07 row 10: paywall loaded — expected logShowPaywallCount 1, got \(Adapty.logShowPaywallCount)")

		// T25 — PM-04 row 8: the paywall was never loaded, so the product is not in the cache.
		// Adapty could not serve this purchase at all — exactly the case the StoreKit fallback
		// exists for, so the expected result is `.retryWithStoreKit`, not `.failed`. Today
		// `AdaptyService.buyProduct` (around :160-161) answers `.failed` for a cache miss — RED.
		Adapty.reset()
		let t25Service = AdaptyService()
		var t25Result: AdaptyPurchaseResult?
		t25Service.buyProduct(placement: "main", id: "year.sub") { t25Result = $0 }
		check(wait { t25Result != nil }, "PM-04 row 8: buyProduct must call back")
		check(isRetryWithStoreKit(t25Result), "PM-04 row 8: an uncached product (paywall never loaded) must answer .retryWithStoreKit, not .failed — got \(String(describing: t25Result))")

		if failures.isEmpty {
			print("AdaptyService paywall retry (PM-07) and purchase fallback (PM-04): 6/6 OK")
		} else {
			print("\(failures.count) check(s) failed:")
			for failure in failures {
				print("  - \(failure)")
			}
			exit(1)
		}
	}
}
