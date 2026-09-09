//
//  AdaptyServiceCheck.swift
//  IntegrationKit
//
//  Covers the approved AD-01…AD-07 risk tables (plus the PM-04/PM-07 rows that pointed here), one
//  assert group per row of those tables. Rows the schemas themselves mark "no test" are listed at
//  the bottom of this comment with their reason, so the gap is visible instead of implied.
//
//  Every assert names the value the schema names — a verdict, a journal entry, a trace line — not
//  the fact that something happened. `count == 0` and `firstMatch.exists` close no row here.
//
//  Deliberately without a test, per the schemas:
//    AD-01 r5 (partly), AD-03 r4, AD-03 r5, AD-05 r3 — SDK or harness boundary;
//    AD-04 r7, AD-06 r4, AD-07 r3 — dead code, closed by deletion, which this file cannot assert.
//  AD-01 r5's own half — "no profile arrived, and nothing said so" — IS covered (T05): the guard
//  belongs to this layer even though the SDK's retry loop behind it does not.
//
//  This check does not stop at the first failing row: every row runs, every failure is collected,
//  and the summary at the end reports all of them with a non-zero exit code.
//  Run:  ./Checks/adapty-service-check.sh
//

import Adapty
import AppTrackingTransparency
import Foundation

/// The `AnalyticsTracking` the service needs to run. `deviceId` is settable because AD-01 row 2 is
/// entirely about what happens when it is still `nil`.
final class FakeAnalytics: AnalyticsTracking {
	var deviceId: String?

	init(deviceId: String? = "device-1") {
		self.deviceId = deviceId
	}

	func configure(apiKey: String, deviceId: String, firstOpenEvent: String?, isTestsRunning: Bool) {}
	func logEvent(_ event: String, properties: [String: Any]?) {}
	func setUserProperties(_ properties: [String: Any]) {}
	func setUserId(_ userId: String) {}
	func updateTrackingAuthorization(_ status: ATTrackingManager.AuthorizationStatus) {}
}

@main
enum AdaptyServiceCheck {
	static var failures: [String] = []
	/// Everything `debugLog` produced since the last `reset()`. Several rows require a trace and
	/// nothing else — see `DebugLog.debugLogSink`.
	static var log: [String] = []

	static let key = "public_live_0000000000000000000000000000000000"

	/// Records a failure instead of trapping — one failing row must not stop every row after it.
	static func check(_ condition: @autoclosure () -> Bool, _ message: @autoclosure () -> String) {
		guard !condition() else { return }
		let text = message()
		failures.append(text)
		print("FAILED: \(text)")
	}

	/// Clears the SDK stub, the issue list and the captured log so one row cannot inherit another's.
	/// The optional label goes to stderr as the row starts — same reason as the section markers in
	/// `main()`, one level finer.
	static func reset(_ row: String = "") {
		if !row.isEmpty { fputs("  \(row)\n", stderr) }
		Adapty.reset()
		ConfigurationIssues.shared.reset()
		log = []
	}

	/// Polls instead of awaiting — the same shape as the other checks.
	@discardableResult
	static func wait(_ seconds: TimeInterval = 2, for condition: () -> Bool) -> Bool {
		let deadline = Date().addingTimeInterval(seconds)
		while Date() < deadline {
			if condition() { return true }
			RunLoop.current.run(until: Date().addingTimeInterval(0.005))
		}
		return condition()
	}

	/// Runs one `async` call to completion on the main run loop.
	static func run<T>(_ work: @escaping () async -> T) -> T? {
		var result: T?
		Task { result = await work() }
		wait(5) { result != nil }
		return result
	}

	static func issues() -> [String] {
		ConfigurationIssues.shared.all
	}

	static func hasIssue(_ fragment: String) -> Bool {
		issues().contains { $0.contains(fragment) }
	}

	static func hasLog(_ fragment: String) -> Bool {
		log.contains { $0.contains(fragment) }
	}

	/// `AdaptyPurchaseResult` carries no `Equatable` conformance (nothing in `Sources/` needs one),
	/// so rows about a verdict compare its name.
	static func name(_ result: AdaptyPurchaseResult?) -> String {
		guard let result else { return "nil" }
		switch result {
			case .success: return "success"
			case .cancelled: return "cancelled"
			case .pending: return "pending"
			case .paidUnconfirmed: return "paidUnconfirmed"
			case .retryWithStoreKit: return "retryWithStoreKit"
			case .unavailable: return "unavailable"
			case .failed: return "failed"
		}
	}

	static func name(_ answer: AdaptyProductsAnswer) -> String {
		switch answer {
			case .products(let products): return "products(\(products.count))"
			case .notReady: return "notReady"
			case .failed: return "failed"
		}
	}

	static func name<T>(_ value: RemoteValue<T>) -> String {
		switch value {
			case .value(let value): return "value(\(value))"
			case .notReady: return "notReady"
			case .noConfig: return "noConfig"
			case .notSet: return "notSet"
			case .wrongType: return "wrongType"
		}
	}

	/// The shipping deadlines with one value shortened, so a row that is about a three-minute wait
	/// runs in a third of a second and still exercises the real code path.
	static func fast(_ field: WritableKeyPath<AdaptyDeadlines, TimeInterval>, _ seconds: TimeInterval) -> AdaptyDeadlines {
		var deadlines = AdaptyDeadlines.default
		deadlines[keyPath: field] = seconds
		return deadlines
	}

	/// A configured, active service with one loaded placement — the starting state most rows need.
	/// `products` is what `getPaywallProducts` will answer with.
	static func loadedService(
		placement: String = "main",
		remoteConfig: [String: Any]? = nil,
		products: [AdaptyPaywallProduct] = [AdaptyPaywallProduct(vendorProductId: "year.sub")]
	) -> AdaptyService {
		Adapty.getPaywallResults = [.success(AdaptyPaywall(remoteConfig: remoteConfig))]
		Adapty.getPaywallProductsResult = .success(products)
		let service = AdaptyService()
		service.configure(apiKey: key, customerUserId: "u1", sessionsCounter: 1, placements: [placement], analytics: FakeAnalytics(), attStatus: .notDetermined)
		return service
	}

	static func main() {
		// Unbuffered: this check drives real timers and can legitimately be slow, and a fully
		// buffered stdout (which is what a pipe or a redirect gives it) makes a slow run and a hung
		// one look identical from outside.
		setvbuf(stdout, nil, _IONBF, 0)
		debugLogSink = { log.append($0) }

		// Section names go to stderr as they start. Several rows drive real `asyncAfter` timers, so
		// a full run takes tens of seconds — without this there is no way to tell a slow row from a
		// stuck one, and stdout stays a single clean summary line.
		let sections: [(String, () -> Void)] = [
			("AD-01 configuration", configuration),
			("AD-02 paywalls", paywalls),
			("AD-03 products", products),
			("AD-04 purchase", purchase),
			("AD-05 profile", profile),
			("AD-06 identity", identity),
			("AD-07 remote values", remoteValues),
			("AD-02…AD-07 amendments", amendments),
		]
		for (name, section) in sections {
			fputs("· \(name)\n", stderr)
			section()
		}

		if failures.isEmpty {
			print("AdaptyService AD-01…AD-07: all checks OK")
		} else {
			print("\(failures.count) check(s) failed:")
			for failure in failures {
				print("  - \(failure)")
			}
			exit(1)
		}
	}

	// MARK: - AD-01: configuration and activation.

	static func configuration() {
		// T01 — AD-01 rows 1 and 7: an empty key. The SDK must not be touched at all: upstream,
		// `Adapty.activate` runs `assert(apiKey.count >= 41 && apiKey.starts(with: "public_live"))`
		// on the caller's own stack, so reaching it takes a DEBUG build down. The stub cannot
		// reproduce that assert, so this proves OUR guard — the assert itself was read in the SDK
		// sources. The process being alive at the end of the row is half the assertion.
		reset("T01")
		let t01 = AdaptyService()
		t01.configure(apiKey: "", customerUserId: "u1", sessionsCounter: 1, placements: ["main"], analytics: FakeAnalytics(), attStatus: .notDetermined)
		check(Adapty.activateCallCount == 0, "AD-01 r1/r7: an empty key must not reach Adapty.activate — got \(Adapty.activateCallCount) activation(s)")
		check(t01.isActive == false, "AD-01 r1/r7: an empty key must leave the layer inactive")
		check(hasIssue("inactive"), "AD-01 r1/r7: an empty key must be recorded as a configuration issue — got \(issues())")

		// T01b — AD-01 row 7, the half an empty key does not reach: a key that is present but is not
		// an Adapty key. `Adapty.activate`'s assert fires on the shape, not on emptiness, so an
		// obfuscated key decrypted wrong trips it just as hard. Both values the schema names are
		// asserted — the SDK stayed untouched, and the reason says what was expected.
		reset("T01b")
		let t01b = AdaptyService()
		t01b.configure(apiKey: "sk_live_not_an_adapty_key_but_long_enough_to_pass_41", customerUserId: "u1", sessionsCounter: 1, placements: ["main"], analytics: FakeAnalytics(), attStatus: .notDetermined)
		check(Adapty.activateCallCount == 0, "AD-01 r7: a key that is not an Adapty key must not reach Adapty.activate — got \(Adapty.activateCallCount) activation(s)")
		check(t01b.isActive == false, "AD-01 r7: a malformed key must leave the layer inactive")
		check(hasIssue("beginning with 'public_live'"), "AD-01 r7: the reason must name the expected shape — got \(issues())")

		// T02 — AD-01 row 2: analytics has no device id yet. An empty string must NOT be written:
		// it looks like an id and joins this profile to nothing forever. Both halves are asserted —
		// nothing reached the SDK, and the reason is readable.
		reset("T02")
		Adapty.getPaywallResults = [.success(AdaptyPaywall())]
		let t02 = AdaptyService()
		t02.configure(apiKey: key, customerUserId: "u1", sessionsCounter: 1, placements: ["main"], analytics: FakeAnalytics(deviceId: nil), attStatus: .notDetermined)
		let t02Written = Adapty.updateProfileJournal.compactMap(\.amplitudeDeviceId)
		check(t02Written.isEmpty, "AD-01 r2: with no analytics device id, amplitudeDeviceId must not be written at all — got \(t02Written)")
		check(hasIssue("no device id"), "AD-01 r2: the missing device id must be recorded — got \(issues())")
		let t02User = Adapty.updateProfileJournal.compactMap(\.amplitudeUserId)
		check(t02User == ["u1"], "AD-01 r2: amplitudeUserId must still be linked — got \(t02User)")

		// T03 — AD-01 row 3: `configure` twice. The SDK rejects the second activation itself
		// (`activateOnceError`, 3005) — what must not happen is the layer carrying on with the REST
		// of the configuration: a second delegate, a second identity write, a second warm-up. The
		// two counters named here are the ones that would grow; asserting "exactly one activation"
		// would only be testing the SDK's own guard.
		reset("T03")
		Adapty.getPaywallResults = [.success(AdaptyPaywall())]
		Adapty.activateErrors = [nil, AdaptyError(.activateOnceError)]
		let t03 = AdaptyService()
		t03.configure(apiKey: key, customerUserId: "u1", sessionsCounter: 1, placements: ["main"], analytics: FakeAnalytics(), attStatus: .notDetermined)
		let t03Paywalls = Adapty.getPaywallCallCount
		let t03Writes = Adapty.updateProfileJournal.count
		t03.configure(apiKey: key, customerUserId: "u1", sessionsCounter: 1, placements: ["main"], analytics: FakeAnalytics(), attStatus: .notDetermined)
		check(Adapty.getPaywallCallCount == t03Paywalls, "AD-01 r3: a rejected second activation must not warm paywalls again — \(t03Paywalls) → \(Adapty.getPaywallCallCount)")
		check(Adapty.updateProfileJournal.count == t03Writes, "AD-01 r3: a rejected second activation must not rewrite the profile — \(t03Writes) → \(Adapty.updateProfileJournal.count)")
		check(hasIssue("activate was rejected"), "AD-01 r3: a rejected activation must be recorded — got \(issues())")

		// T04 — AD-01 row 4 / AD-02 row 3: `refreshPaywalls` fires while the first request is still
		// in flight. The stub holds the answer, so the request genuinely has not finished. The SDK
		// de-duplicates nothing (it opens a task per call), so the second request must be suppressed
		// here or not at all.
		reset("T04")
		Adapty.holdGetPaywall = true
		let t04 = AdaptyService()
		t04.configure(apiKey: key, customerUserId: "u1", sessionsCounter: 1, placements: ["main"], analytics: FakeAnalytics(), attStatus: .notDetermined)
		t04.refreshPaywalls()
		t04.refreshPaywalls()
		check(Adapty.getPaywallCallCount == 1, "AD-01 r4: a request already in flight must not be duplicated — expected 1 getPaywall, got \(Adapty.getPaywallCallCount)")

		// T05 — AD-01 row 5: an invalid key produces no error anywhere; the SDK re-creates the
		// profile once a second forever (its own source carries the `TODO` where the give-up should
		// be). The only symptom this layer can see is that no profile ever arrives, and the schema
		// asks for that to be visible. The deadline is injected so the row runs in half a second.
		reset("T05")
		Adapty.getPaywallResults = [.success(AdaptyPaywall())]
		let t05 = AdaptyService(deadlines: fast(\.firstProfile, 0.2))
		t05.configure(apiKey: key, customerUserId: "u1", sessionsCounter: 1, placements: ["main"], analytics: FakeAnalytics(), attStatus: .notDetermined)
		wait(1) { hasIssue("no profile") }
		check(hasIssue("no profile"), "AD-01 r5: a profile that never arrives must be recorded — got \(issues())")

		// T05b — the same guard must stay quiet when a profile DID arrive, or the line is noise.
		reset("T05b")
		Adapty.getPaywallResults = [.success(AdaptyPaywall())]
		let t05b = AdaptyService(deadlines: fast(\.firstProfile, 0.2))
		t05b.configure(apiKey: key, customerUserId: "u1", sessionsCounter: 1, placements: ["main"], analytics: FakeAnalytics(), attStatus: .notDetermined)
		t05b.didLoadLatestProfile(AdaptyProfile(accessLevels: [:]))
		wait(0.5) { false }
		check(!hasIssue("no profile"), "AD-01 r5: a profile that did arrive must not be reported as missing — got \(issues())")

		// T06 — AD-01 row 6: an empty placement list is legal but is almost always an integration
		// mistake, so it has to be visible.
		reset("T06")
		let t06 = AdaptyService()
		t06.configure(apiKey: key, customerUserId: "u1", sessionsCounter: 1, placements: [], analytics: FakeAnalytics(), attStatus: .notDetermined)
		check(hasIssue("no placements"), "AD-01 r6: an empty placement list must be recorded — got \(issues())")
	}

	// MARK: - AD-02: paywalls.

	static func paywalls() {
		// T07 — AD-02 row 1: a placement that does not exist answers `badRequest` (2003) and will
		// answer it forever. Retrying it is a typo burning battery for the life of the process. The
		// pair of asserts is the point of the row: the SAME failure with a network code must keep
		// retrying. Timing is not measured — `asyncAfter` is not fast-forwardable in this harness,
		// so the assert names attempt counts.
		reset()
		Adapty.getPaywallResults = [.failure(AdaptyError(.badRequest))]
		let t07 = AdaptyService()
		t07.configure(apiKey: key, customerUserId: "u1", sessionsCounter: 1, placements: ["typo"], analytics: FakeAnalytics(), attStatus: .notDetermined)
		wait(1) { Adapty.getPaywallCallCount > 1 }
		check(Adapty.getPaywallCallCount == 1, "AD-02 r1: badRequest must not be retried — expected exactly 1 getPaywall, got \(Adapty.getPaywallCallCount)")
		check(hasIssue("has no placement 'typo'"), "AD-02 r1: an unknown placement must be recorded by name — got \(issues())")
		t07.refreshPaywalls()
		check(Adapty.getPaywallCallCount == 1, "AD-02 r1: a foreground trigger must not revive a badRequest placement — got \(Adapty.getPaywallCallCount)")

		reset()
		Adapty.getPaywallResults = [.failure(AdaptyError(.networkFailed))]
		let t07b = AdaptyService()
		t07b.configure(apiKey: key, customerUserId: "u1", sessionsCounter: 1, placements: ["main"], analytics: FakeAnalytics(), attStatus: .notDetermined)
		check(wait(2) { Adapty.getPaywallCallCount >= 2 }, "AD-02 r1: networkFailed must keep retrying — expected at least 2 getPaywall attempts, got \(Adapty.getPaywallCallCount)")
		check(!hasIssue("has no placement"), "AD-02 r1: a network failure is not a configuration issue — got \(issues())")

		// T08 — AD-02 row 2 / AD-03 row 2: the paywall arrived, the products did not. The SDK has
		// already spent its own three attempts by the time this answer lands, so there is nothing to
		// retry — the defect is the silence afterwards. Code 1000 covers two causes the SDK cannot
		// separate (a paywall with no products, products the store does not know), so AD-02 row 6
		// requires the code itself in the trace: one cause is fixed in the dashboard, the other in
		// App Store Connect.
		reset()
		Adapty.getPaywallResults = [.success(AdaptyPaywall())]
		Adapty.getPaywallProductsResult = .failure(AdaptyError(.noProductIDsFound))
		let t08 = AdaptyService()
		t08.configure(apiKey: key, customerUserId: "u1", sessionsCounter: 1, placements: ["main"], analytics: FakeAnalytics(), attStatus: .notDetermined)
		check(t08.failedProductLoads == 1, "AD-02 r2: a failed product load must be counted — expected 1, got \(t08.failedProductLoads)")
		check(hasLog("noProductIDsFound"), "AD-02 r6: the trace must name the SDK code, not just 'no products' — got \(log)")

		// T09 — AD-02 row 4: a paywall edited in the dashboard mid-session used to be cached until
		// the process died. With the TTL expired, a foreground trigger reloads it.
		reset()
		Adapty.getPaywallResults = [.success(AdaptyPaywall())]
		let t09 = AdaptyService(deadlines: fast(\.paywallTTL, 0))
		t09.configure(apiKey: key, customerUserId: "u1", sessionsCounter: 1, placements: ["main"], analytics: FakeAnalytics(), attStatus: .notDetermined)
		let t09First = Adapty.getPaywallCallCount
		t09.refreshPaywalls()
		check(Adapty.getPaywallCallCount == t09First + 1, "AD-02 r4: a stale paywall must be reloaded on the next foreground — \(t09First) → \(Adapty.getPaywallCallCount)")

		// T09b — and a fresh one must not be, or every foreground costs a request per placement.
		reset()
		Adapty.getPaywallResults = [.success(AdaptyPaywall())]
		let t09b = AdaptyService(deadlines: fast(\.paywallTTL, 600))
		t09b.configure(apiKey: key, customerUserId: "u1", sessionsCounter: 1, placements: ["main"], analytics: FakeAnalytics(), attStatus: .notDetermined)
		let t09bFirst = Adapty.getPaywallCallCount
		t09b.refreshPaywalls()
		check(Adapty.getPaywallCallCount == t09bFirst, "AD-02 r4: a fresh paywall must not be reloaded — \(t09bFirst) → \(Adapty.getPaywallCallCount)")

		// T10 — AD-02 row 5: three different reasons for "no paywall", three different answers. One
		// boolean cannot tell a screen whether to draw a spinner or an empty state.
		reset()
		Adapty.holdGetPaywall = true
		let t10 = AdaptyService()
		t10.configure(apiKey: key, customerUserId: "u1", sessionsCounter: 1, placements: ["main"], analytics: FakeAnalytics(), attStatus: .notDetermined)
		check(t10.paywallState(placement: "main") == .loading, "AD-02 r5: a request in flight must read as .loading, got \(t10.paywallState(placement: "main"))")
		check(t10.paywallState(placement: "never-configured") == .unavailable, "AD-02 r5: a placement nobody configured must read as .unavailable, got \(t10.paywallState(placement: "never-configured"))")
		Adapty.releaseHeldPaywall(.success(AdaptyPaywall()))
		check(t10.paywallState(placement: "main") == .ready, "AD-02 r5: a loaded paywall must read as .ready, got \(t10.paywallState(placement: "main"))")

		// T10b — and the fourth: a placement Adapty rejected is not "loading" either.
		reset()
		Adapty.getPaywallResults = [.failure(AdaptyError(.badRequest))]
		let t10b = AdaptyService()
		t10b.configure(apiKey: key, customerUserId: "u1", sessionsCounter: 1, placements: ["typo"], analytics: FakeAnalytics(), attStatus: .notDetermined)
		check(t10b.paywallState(placement: "typo") == .unavailable, "AD-02 r5: a placement Adapty rejected must read as .unavailable, got \(t10b.paywallState(placement: "typo"))")

		// T11 — PM-07 row 8, kept from the previous revision: an always-failing placement retries by
		// itself, and the retries stay spaced. Both bounds come from one sentence of the schema —
		// loading continues until it succeeds, and it must not become a tight loop.
		reset()
		Adapty.getPaywallResults = [.failure(AdaptyError(.networkFailed))]
		let t11 = AdaptyService()
		t11.configure(apiKey: key, customerUserId: "u1", sessionsCounter: 1, placements: ["main"], analytics: FakeAnalytics(), attStatus: .notDetermined)
		wait(1) { Adapty.getPaywallCallCount >= 5 }
		let t11Count = Adapty.getPaywallCallCount
		check(t11.hasPaywall(placement: "main") == false, "PM-07 r8: an always-failing placement must never report hasPaywall true")
		check(t11Count >= 2, "PM-07 r8: a failed load must retry on its own — expected at least 2 attempts within a second, got \(t11Count)")
		check(t11Count <= 5, "PM-07 r8: the retry must stay spaced, never a tight loop — expected at most 5 attempts in that second, got \(t11Count)")

		// T12 — PM-07 row 8: a successful retry is applied, not merely attempted.
		reset()
		Adapty.getPaywallResults = [.failure(AdaptyError(.networkFailed)), .success(AdaptyPaywall())]
		let t12 = AdaptyService()
		t12.configure(apiKey: key, customerUserId: "u1", sessionsCounter: 1, placements: ["main"], analytics: FakeAnalytics(), attStatus: .notDetermined)
		t12.refreshPaywalls()
		check(t12.hasPaywall(placement: "main") == true, "PM-07 r8: a successful retry must be applied — hasPaywall is still false")
		check(Adapty.getPaywallCallCount >= 2, "PM-07 r8: expected at least 2 getPaywall attempts, got \(Adapty.getPaywallCallCount)")

		// T13 — PM-07 row 8: retry chains must not stack. Four triggers are four immediate attempts,
		// which is correct; what must not follow is four independent chains hammering the SDK.
		reset()
		Adapty.getPaywallResults = [.failure(AdaptyError(.networkFailed))]
		let t13 = AdaptyService(deadlines: fast(\.paywallTTL, 0))
		t13.configure(apiKey: key, customerUserId: "u1", sessionsCounter: 1, placements: ["main"], analytics: FakeAnalytics(), attStatus: .notDetermined)
		t13.refreshPaywalls()
		t13.refreshPaywalls()
		t13.refreshPaywalls()
		let t13Immediate = Adapty.getPaywallCallCount
		check(t13Immediate == 4, "PM-07 r8: configure plus three foreground triggers must each attempt once — expected 4, got \(t13Immediate)")
		wait(1) { false }
		check(Adapty.getPaywallCallCount <= 6, "PM-07 r8: retry chains must not stack per trigger — expected at most 6 attempts a second later, got \(Adapty.getPaywallCallCount)")
	}

	// MARK: - AD-03: products.

	static func products() {
		// T14 — AD-03 row 1: two causes, two answers. `count == 0` is identical in both and proves
		// nothing, so the assert names the case.
		reset()
		let t14 = AdaptyService()
		t14.configure(apiKey: key, customerUserId: "u1", sessionsCounter: 1, placements: ["main"], analytics: FakeAnalytics(), attStatus: .notDetermined)
		let t14NoPaywall = run { await t14.products(placement: "main") }
		check(name(t14NoPaywall ?? .failed) == "notReady", "AD-03 r1: with no paywall loaded the answer must be .notReady, got \(name(t14NoPaywall ?? .failed))")

		reset()
		Adapty.getPaywallResults = [.success(AdaptyPaywall())]
		Adapty.getPaywallProductsResult = .failure(AdaptyError(.noProductIDsFound))
		let t14b = AdaptyService()
		t14b.configure(apiKey: key, customerUserId: "u1", sessionsCounter: 1, placements: ["main"], analytics: FakeAnalytics(), attStatus: .notDetermined)
		let t14bFailed = run { await t14b.products(placement: "main") }
		check(name(t14bFailed ?? .notReady) == "failed", "AD-03 r1: with the paywall loaded and the listing failing the answer must be .failed, got \(name(t14bFailed ?? .notReady))")

		// T15 — AD-03 row 2: the same failure, counted. It is the same event as AD-02 row 2 on the
		// other code path, so it shares one counter — here it must reach 2, because both paths ran.
		check(t14b.failedProductLoads == 2, "AD-03 r2: both product-load paths must feed one counter — expected 2, got \(t14b.failedProductLoads)")

		// T16 — AD-03 row 3: the store gave no formatted price. A missing price must stay missing;
		// an empty string is a price that renders as nothing and cannot be told from a real one.
		reset()
		let t16 = loadedService(products: [AdaptyPaywallProduct(vendorProductId: "year.sub", localizedPrice: nil)])
		let t16Answer = run { await t16.products(placement: "main") }
		if case .products(let list) = t16Answer ?? .notReady, let first = list.first {
			check(first.localizedPrice == nil, "AD-03 r3: a missing localizedPrice must stay nil, got \(String(describing: first.localizedPrice))")
		} else {
			check(false, "AD-03 r3 setup: expected products, got \(name(t16Answer ?? .notReady))")
		}
	}

	// MARK: - AD-04: purchase.

	static func purchase() {
		// T17 — AD-04 row 4: three causes that used to share one `retryWithStoreKit`. The one that
		// matters most is the inactive layer: a silent fallback there takes money through a door the
		// app never opened.
		reset()
		let t17Inactive = AdaptyService()
		t17Inactive.configure(apiKey: "", customerUserId: "u1", sessionsCounter: 1, placements: ["main"], analytics: FakeAnalytics(), attStatus: .notDetermined)
		var t17InactiveResult: AdaptyPurchaseResult?
		t17Inactive.buyProduct(placement: "main", id: "year.sub") { t17InactiveResult = $0 }
		check(name(t17InactiveResult) == "failed", "AD-04 r4: an inactive layer must not fall back to StoreKit — expected .failed, got \(name(t17InactiveResult))")
		check(hasIssue("inactive"), "AD-04 r4: a purchase against an inactive layer must be recorded — got \(issues())")

		reset()
		let t17NoPaywall = AdaptyService()
		t17NoPaywall.configure(apiKey: key, customerUserId: "u1", sessionsCounter: 1, placements: ["main"], analytics: FakeAnalytics(), attStatus: .notDetermined)
		var t17NoPaywallResult: AdaptyPurchaseResult?
		t17NoPaywall.buyProduct(placement: "main", id: "year.sub") { t17NoPaywallResult = $0 }
		check(name(t17NoPaywallResult) == "retryWithStoreKit", "AD-04 r4/PM-04 r8: an unloaded paywall must answer .retryWithStoreKit, got \(name(t17NoPaywallResult))")

		reset()
		let t17WrongId = loadedService(products: [AdaptyPaywallProduct(vendorProductId: "year.sub")])
		var t17WrongIdResult: AdaptyPurchaseResult?
		t17WrongId.buyProduct(placement: "main", id: "month.sub") { t17WrongIdResult = $0 }
		check(name(t17WrongIdResult) == "unavailable", "AD-04 r4: an id the loaded paywall does not sell must answer .unavailable, got \(name(t17WrongIdResult))")
		check(hasIssue("is not on Adapty placement"), "AD-04 r4: a product the paywall does not sell must be recorded — got \(issues())")

		// T18 — AD-04 row 2: Apple charged and Adapty could not confirm. Codes 2004 and 2005 used to
		// go down different branches — one into a SECOND purchase through StoreKit — which is how a
		// paid user was asked to pay twice. Both codes are asserted, because one alone would not
		// show that they disagreed.
		for code in [AdaptyError.ErrorCode.serverError, .networkFailed] {
			reset()
			let service = loadedService()
			Adapty.makePurchaseResult = .failure(AdaptyError(code))
			var result: AdaptyPurchaseResult?
			service.buyProduct(placement: "main", id: "year.sub") { result = $0 }
			check(name(result) == "paidUnconfirmed", "AD-04 r2: \(code) means Apple charged and Adapty could not confirm — expected .paidUnconfirmed, got \(name(result))")
		}

		// T19 — AD-04 row 3: a promotional offer the store refuses to sign. This fails before any
		// payment is queued, so the fallback would buy the same product at full price, silently,
		// right after the user was shown a discount. The verdict has to differ from the ordinary
		// `retryWithStoreKit`.
		for code in [AdaptyError.ErrorCode.invalidOfferIdentifier, .invalidSignature, .missingOfferParams, .invalidOfferPrice] {
			reset()
			let service = loadedService()
			Adapty.makePurchaseResult = .failure(AdaptyError(code))
			var result: AdaptyPurchaseResult?
			service.buyProduct(placement: "main", id: "year.sub") { result = $0 }
			check(name(result) == "unavailable", "AD-04 r3: an unsigned promotional offer (\(code)) must not silently buy at full price — expected .unavailable, got \(name(result))")
		}

		// T20 — AD-04 row 5: a permanent refusal must not look like a temporary one. Parental
		// controls answer the same way on every retry, so the button should go away instead of
		// failing again. 2005 is deliberately absent here: row 2 gives it the more specific verdict,
		// and both rows agree it is not a permanent refusal.
		for code in [AdaptyError.ErrorCode.cantMakePayments, .paymentNotAllowed, .storeProductNotAvailable] {
			reset()
			let service = loadedService()
			Adapty.makePurchaseResult = .failure(AdaptyError(code))
			var result: AdaptyPurchaseResult?
			service.buyProduct(placement: "main", id: "year.sub") { result = $0 }
			check(name(result) == "unavailable", "AD-04 r5: \(code) is permanent for this device — expected .unavailable, got \(name(result))")
			check(hasIssue("cannot be purchased on this device"), "AD-04 r5: a permanent refusal must be recorded — got \(issues())")
		}
		reset()
		let t20Temp = loadedService()
		Adapty.makePurchaseResult = .failure(AdaptyError(.networkFailed))
		var t20TempResult: AdaptyPurchaseResult?
		t20Temp.buyProduct(placement: "main", id: "year.sub") { t20TempResult = $0 }
		check(name(t20TempResult) != "unavailable", "AD-04 r5: networkFailed is temporary and must not read as a permanent refusal, got \(name(t20TempResult))")

		// T21 — AD-04, the branch verified as already correct: a user cancel arrives as the raw
		// SKError (2), not wrapped, so it must map to `.cancelled` and nothing else.
		reset()
		let t21 = loadedService()
		Adapty.makePurchaseResult = .failure(AdaptyError(.paymentCancelled))
		var t21Result: AdaptyPurchaseResult?
		t21.buyProduct(placement: "main", id: "year.sub") { t21Result = $0 }
		check(name(t21Result) == "cancelled", "AD-04: a user cancel must map to .cancelled, got \(name(t21Result))")

		// T22 — AD-04 row 6: the log line an incident starts from. The code is in the line already
		// and would be green from the start, so the assert names the two things that were missing:
		// the product id and the verdict this layer decided on.
		reset()
		let t22 = loadedService()
		Adapty.makePurchaseResult = .failure(AdaptyError(.cantMakePayments))
		t22.buyProduct(placement: "main", id: "year.sub", completion: nil)
		check(hasLog("year.sub"), "AD-04 r6: the failure log must name the product id — got \(log)")
		check(hasLog("unavailable"), "AD-04 r6: the failure log must name the verdict this layer decided — got \(log)")

		// T23 — AD-04 row 1, the most expensive row of the schema: the SDK accepts the purchase and
		// never calls back. Upstream that is not hypothetical — on `deferred` and `purchasing` the
		// queue manager does nothing at all and leaves the registered handler lying in its
		// dictionary, so only a later `purchased` state in the same process can ever wake it.
		//
		// Two asserts, both required by the row. First: the wait ends in a verdict, and the verdict
		// is WAITING — not a failure the user is invited to retry into a second charge. Second: the
		// machinery is free afterwards, which is the half that mattered most, since one hung purchase
		// used to refuse every later purchase in the process.
		reset()
		Adapty.getPaywallResults = [.success(AdaptyPaywall())]
		Adapty.getPaywallProductsResult = .success([AdaptyPaywallProduct(vendorProductId: "year.sub")])
		let t23 = AdaptyService(deadlines: fast(\.purchase, 0.3))
		t23.configure(apiKey: key, customerUserId: "u1", sessionsCounter: 1, placements: ["main"], analytics: FakeAnalytics(), attStatus: .notDetermined)
		Adapty.holdMakePurchase = true
		let t23Started = Date()
		let t23Result = run { await t23.buy(productId: "year.sub", placement: "main") }
		check(name(t23Result) == "pending", "AD-04 r1: a purchase the SDK never answers must settle as .pending, got \(name(t23Result))")
		check(Date().timeIntervalSince(t23Started) < 2, "AD-04 r1: it must settle on its own deadline, took \(Date().timeIntervalSince(t23Started))s")

		Adapty.holdMakePurchase = false
		Adapty.makePurchaseResult = .success(())
		let t23Second = run { await t23.buy(productId: "year.sub", placement: "main") }
		check(name(t23Second) == "success", "AD-04 r1: the purchase after a hung one must go through — got \(name(t23Second))")
	}

	// MARK: - AD-05: profile and receipt.

	static func profile() {
		// T24 — AD-05 row 1: `getProfile` is called and never answered. Upstream that is a real
		// state, not a hypothetical: on a first launch whose profile cannot be created the SDK wakes
		// only its other bucket of handlers and retries once a second forever. The assert names the
		// return and the time, not the value — `nil` also comes back from a working call.
		reset()
		Adapty.holdGetProfile = true
		let t24 = AdaptyService(deadlines: fast(\.call, 0.3))
		t24.configure(apiKey: key, customerUserId: "u1", sessionsCounter: 1, placements: [], analytics: FakeAnalytics(), attStatus: .notDetermined)
		var t24Returned = false
		let t24Started = Date()
		Task {
			_ = await t24.profile()
			t24Returned = true
		}
		check(wait(3) { t24Returned }, "AD-05 r1: profile() must return even when the SDK never answers")
		check(Date().timeIntervalSince(t24Started) < 2, "AD-05 r1: profile() must return on its own deadline, took \(Date().timeIntervalSince(t24Started))s")

		// T25 — AD-05 row 2: the first push of a process carries the profile the SDK had on DISK.
		// A stale "no premium" from the last launch must not read as a checked denial. The service
		// half of the row is the provenance flag; the resolver half lives in PremiumResolverCheck.
		reset()
		Adapty.getPaywallResults = [.success(AdaptyPaywall())]
		let t25 = AdaptyService()
		var t25Pushes: [Bool] = []
		t25.premiumObserver = { _, isVerified in t25Pushes.append(isVerified) }
		t25.configure(apiKey: key, customerUserId: "u1", sessionsCounter: 1, placements: ["main"], analytics: FakeAnalytics(), attStatus: .notDetermined)
		t25.didLoadLatestProfile(AdaptyProfile(accessLevels: [:]))
		t25.didLoadLatestProfile(AdaptyProfile(accessLevels: [:]))
		check(t25Pushes == [false, true], "AD-05 r2: the first push is unverified (from disk), later ones are not — got \(t25Pushes)")

		// T26 — AD-05 row 4: `syncReceipt` used to throw its result away, at the one moment Adapty
		// is guaranteed not to know about the purchase yet.
		reset()
		let t26 = loadedService()
		Adapty.restorePurchasesResult = .failure(AdaptyError(.networkFailed))
		t26.syncReceipt()
		check(t26.failedSyncs == 1, "AD-05 r4: a failed sync must be counted — expected 1, got \(t26.failedSyncs)")
		check(hasIssue("did not pick up a local purchase"), "AD-05 r4: a failed sync must be recorded — got \(issues())")

		// T27 — AD-05 row 5: three failures, one answer to the caller (`nil`, which is right), but
		// only ONE of them is a configuration mistake. Both halves are asserted: the sameness of the
		// answer and the difference in the trace.
		reset()
		let t27Inactive = AdaptyService()
		t27Inactive.configure(apiKey: "", customerUserId: "u1", sessionsCounter: 1, placements: [], analytics: FakeAnalytics(), attStatus: .notDetermined)
		ConfigurationIssues.shared.reset()
		let t27InactiveAnswer = run { await t27Inactive.profile() }
		check((t27InactiveAnswer ?? nil) == nil, "AD-05 r5: an inactive layer must answer nil")
		check(hasIssue("inactive"), "AD-05 r5: an inactive layer must leave a configuration issue — got \(issues())")

		for code in [AdaptyError.ErrorCode.profileWasChanged, .serverError] {
			reset()
			let service = AdaptyService()
			service.configure(apiKey: key, customerUserId: "u1", sessionsCounter: 1, placements: [], analytics: FakeAnalytics(), attStatus: .notDetermined)
			ConfigurationIssues.shared.reset()
			Adapty.getProfileResult = .failure(AdaptyError(code))
			let answer = run { await service.profile() }
			check((answer ?? nil) == nil, "AD-05 r5: \(code) must answer nil")
			check(issues().isEmpty, "AD-05 r5: \(code) is not a configuration mistake and must not be recorded — got \(issues())")
		}
	}

	// MARK: - AD-06: identity and attribution.

	static func identity() {
		// T28 — AD-06 row 1: conversion data racing ahead of activation. Install data arrives once
		// per install; a write lost to that race means this user's campaign never pays back on any
		// dashboard. The assert names the REPEAT — the first call happens today too.
		reset()
		Adapty.getPaywallResults = [.success(AdaptyPaywall())]
		let t28 = AdaptyService()
		t28.updateAppsFlyerAttribution(["af_status": "Organic"], networkUserId: "af-uid-1")
		check(Adapty.updateAttributionJournal.isEmpty, "AD-06 r1 setup: a write before activation must not reach the SDK — got \(Adapty.updateAttributionJournal.count)")
		t28.configure(apiKey: key, customerUserId: "u1", sessionsCounter: 1, placements: ["main"], analytics: FakeAnalytics(), attStatus: .notDetermined)
		let t28Ids = Adapty.updateAttributionJournal.map { $0.networkUserId ?? "nil" }
		check(t28Ids == ["af-uid-1"], "AD-06 r1: the queued attribution must be repeated after activation with the same networkUserId — got \(t28Ids)")

		// T29 — AD-06 row 2: a profile write the SDK never answers. On a cold offline first launch
		// the write silently does not happen and nothing anywhere says so.
		reset()
		Adapty.holdUpdateProfile = true
		let t29 = AdaptyService(deadlines: fast(\.write, 0.2))
		t29.configure(apiKey: key, customerUserId: "u1", sessionsCounter: 1, placements: [], analytics: FakeAnalytics(), attStatus: .notDetermined)
		wait(1) { hasIssue("never answered a profile write") }
		check(hasIssue("never answered a profile write"), "AD-06 r2: a profile write that never comes back must be recorded — got \(issues())")

		// T30 — AD-06 row 3: a value Adapty refuses. The live input is a deep link value straight off
		// the network, which disappears at character 51. Both halves: nothing reached the SDK, and
		// the reason is readable with the key in it.
		reset()
		let t30 = loadedService()
		let t30Before = Adapty.updateProfileJournal.count
		t30.setProfileValue(value: String(repeating: "x", count: 51), key: "deep_link_value")
		check(Adapty.updateProfileJournal.count == t30Before, "AD-06 r3: an over-long value must not reach the SDK — journal grew from \(t30Before) to \(Adapty.updateProfileJournal.count)")
		check(hasIssue("'deep_link_value' was not written"), "AD-06 r3: the refusal must name the key — got \(issues())")
		check(hasIssue("1…50 characters (got 51)"), "AD-06 r3: the refusal must name the reason — got \(issues())")

		// T30b — and a legal value must still go through, or the guard is just a mute button.
		reset()
		let t30b = loadedService()
		t30b.setProfileValue(value: "summer_sale", key: "deep_link_value")
		let t30bWritten = Adapty.updateProfileJournal.compactMap { $0.customAttributes["deep_link_value"] }
		check(t30bWritten == ["summer_sale"], "AD-06 r3: a legal value must reach the SDK — got \(t30bWritten)")

		// T31 — AD-06 row 5: an inactive layer. Every operation must stop before the SDK, and the
		// cause must land exactly ONCE, not once per operation.
		reset()
		let t31 = AdaptyService()
		t31.configure(apiKey: "", customerUserId: "u1", sessionsCounter: 1, placements: ["main"], analytics: FakeAnalytics(), attStatus: .notDetermined)
		t31.setProfileValue(value: "v", key: "k")
		t31.updateAppTrackingTransparencyStatus(.authorized)
		t31.updateAppsFlyerAttribution([:], networkUserId: "af")
		t31.syncReceipt()
		t31.logPaywallOpen(placement: "main")
		check(Adapty.updateProfileJournal.isEmpty, "AD-06 r5: an inactive layer must write no profile — got \(Adapty.updateProfileJournal.count)")
		check(Adapty.updateAttributionJournal.isEmpty, "AD-06 r5: an inactive layer must write no attribution — got \(Adapty.updateAttributionJournal.count)")
		check(Adapty.restorePurchasesCallCount == 0, "AD-06 r5: an inactive layer must not sync — got \(Adapty.restorePurchasesCallCount)")
		check(Adapty.logShowPaywallCount == 0, "AD-06 r5: an inactive layer must log no impression — got \(Adapty.logShowPaywallCount)")
		check(issues().count == 1, "AD-06 r5: an inactive layer must record ONE line, not one per operation — got \(issues())")

		// T32 — AD-06 row 6: the ATT status is state, not install data. A user who changes it in
		// Settings would otherwise leave Adapty on the answer given at the first system dialog
		// forever, so every launch sends the current value. Two launches with DIFFERENT answers, and
		// the assert names both values — "two writes happened" would stay green if the second launch
		// resent the first launch's stale status.
		reset("T32")
		Adapty.getPaywallResults = [.success(AdaptyPaywall())]
		let t32 = AdaptyService()
		t32.configure(apiKey: key, customerUserId: "u1", sessionsCounter: 1, placements: ["main"], analytics: FakeAnalytics(), attStatus: .denied)
		let t32First = Adapty.updateProfileJournal.compactMap(\.attStatus)
		check(t32First == [.denied], "AD-06 r6: configure must send the current ATT status — got \(t32First)")
		let t32Second = AdaptyService()
		t32Second.configure(apiKey: key, customerUserId: "u2", sessionsCounter: 2, placements: ["main"], analytics: FakeAnalytics(), attStatus: .authorized)
		let t32Both = Adapty.updateProfileJournal.compactMap(\.attStatus)
		check(t32Both == [.denied, .authorized], "AD-06 r6: the next launch must send the CURRENT status again, not the first one — got \(t32Both)")
	}

	// MARK: - AD-07: remote values and impressions.

	static func remoteValues() {
		// T33 — AD-07 row 1: four causes that used to be one `nil`. `nil` comes back in all four
		// today and proves nothing, so every assert names the case.
		reset()
		Adapty.holdGetPaywall = true
		let t33NoPaywall = AdaptyService()
		t33NoPaywall.configure(apiKey: key, customerUserId: "u1", sessionsCounter: 1, placements: ["main"], analytics: FakeAnalytics(), attStatus: .notDetermined)
		let t33A: RemoteValue<Int> = t33NoPaywall.getRemoteValue(placement: "main", key: "count")
		check(name(t33A) == "notReady", "AD-07 r1: a paywall that has not arrived must read as .notReady, got \(name(t33A))")

		reset()
		let t33NoConfig = loadedService(remoteConfig: nil)
		let t33B: RemoteValue<Int> = t33NoConfig.getRemoteValue(placement: "main", key: "count")
		check(name(t33B) == "noConfig", "AD-07 r1: a paywall with no remote config must read as .noConfig, got \(name(t33B))")

		reset()
		let t33Config = loadedService(remoteConfig: ["count": 42])
		let t33C: RemoteValue<Int> = t33Config.getRemoteValue(placement: "main", key: "missing")
		check(name(t33C) == "notSet", "AD-07 r1: a key the config does not carry must read as .notSet, got \(name(t33C))")
		let t33D: RemoteValue<String> = t33Config.getRemoteValue(placement: "main", key: "count")
		check(name(t33D) == "wrongType", "AD-07 r1: a value of another type must read as .wrongType, got \(name(t33D))")
		check(hasIssue("'count' on 'main'"), "AD-07 r1: a dashboard type mismatch must be recorded with the key — got \(issues())")
		let t33E: RemoteValue<Int> = t33Config.getRemoteValue(placement: "main", key: "count")
		check(name(t33E) == "value(42)", "AD-07 r1: the right-typed read must still work, got \(name(t33E))")

		// T34 — AD-07 row 5: the SDK's `remoteConfig` re-runs JSONSerialization on every access, and
		// a paywall screen reads a handful of keys while it lays itself out. Three reads, one parse.
		reset()
		let t34 = loadedService(remoteConfig: ["a": 1, "b": 2, "c": 3])
		let t34Baseline = AdaptyPaywall.parseCount
		let _: RemoteValue<Int> = t34.getRemoteValue(placement: "main", key: "a")
		let _: RemoteValue<Int> = t34.getRemoteValue(placement: "main", key: "b")
		let _: RemoteValue<Int> = t34.getRemoteValue(placement: "main", key: "c")
		check(AdaptyPaywall.parseCount == t34Baseline, "AD-07 r5: reading three keys must not re-parse the config — \(t34Baseline) → \(AdaptyPaywall.parseCount) parses")
		check(t34Baseline >= 1, "AD-07 r5 setup: the config must have been parsed once at load time, got \(t34Baseline)")

		// T35 — AD-07 row 2 / PM-07 row 10: an impression for a paywall that is not loaded. Nothing
		// can be sent (there is no variationId), but a purchase can still happen through the
		// fallback, so the skipped impression must leave a trace instead of nothing.
		reset()
		let t35 = AdaptyService()
		t35.configure(apiKey: key, customerUserId: "u1", sessionsCounter: 1, placements: ["main"], analytics: FakeAnalytics(), attStatus: .notDetermined)
		t35.logPaywallOpen(placement: "main")
		check(Adapty.logShowPaywallCount == 0, "AD-07 r2: no paywall means no impression can be sent — got \(Adapty.logShowPaywallCount)")
		check(hasLog("impression not counted"), "AD-07 r2: a skipped impression must leave a trace — got \(log)")

		// T36 — PM-07 row 10, the positive: a loaded paywall logs exactly one impression.
		reset()
		let t36 = loadedService()
		let t36Before = Adapty.logShowPaywallCount
		t36.logPaywallOpen(placement: "main")
		check(Adapty.logShowPaywallCount == t36Before + 1, "PM-07 r10: a loaded paywall must log exactly one impression — \(t36Before) → \(Adapty.logShowPaywallCount)")

		// T37 — AD-07 row 4: both event calls used to discard the SDK's completion, so a dropped
		// impression looked exactly like a sent one.
		reset()
		let t37 = loadedService()
		Adapty.logShowPaywallError = AdaptyError(.networkFailed)
		t37.logPaywallOpen(placement: "main")
		check(hasLog("logShowPaywall failed for 'main'"), "AD-07 r4: a failed impression must leave an error line naming the placement — got \(log)")

		// T38 — PM-07 row 1, kept from the previous revision: an unconfigured placement degrades to
		// nothing rather than into a trap.
		reset()
		let t38 = loadedService()
		check(t38.hasPaywall(placement: "nope") == false, "PM-07 r1: an unconfigured placement must report no paywall")
		check(t38.hasProductsForPaywall(placement: "nope") == false, "PM-07 r1: an unconfigured placement must report no products")
		let t38Remote: RemoteValue<String> = t38.getRemoteValue(placement: "nope", key: "any")
		check(name(t38Remote) == "notReady", "PM-07 r1: an unconfigured placement must have no remote config, got \(name(t38Remote))")
	}

	// MARK: - Amendments: rows the schemas assert that nothing pinned.
	//
	// Appended at the end on purpose. The rows of the AD tables name their checks by test id, not by
	// line, but every risk row added with these carries `file:line`, and a new section spliced into
	// the middle of the file would move those the day the next row is written.

	static func amendments() {
		// T39 — AD-02 row 7: the paywall-cache observer. The schema's side-effect table promises the
		// screen is woken on every change of the cache, and AD-02 row 1 promises the same wake for a
		// placement Adapty rejects — a wake with no paywall behind it. Nothing pinned either half, and
		// the second one is the expensive one: without it a typo'd placement leaves the screen on its
		// spinner for the life of the process, which is exactly the state `paywallState` was added to
		// make visible.
		reset("T39")
		Adapty.holdGetPaywall = true
		let t39 = AdaptyService()
		var t39Wakes = 0
		t39.observer = { t39Wakes += 1 }
		t39.configure(apiKey: key, customerUserId: "u1", sessionsCounter: 1, placements: ["main"], analytics: FakeAnalytics(), attStatus: .notDetermined)
		check(t39Wakes == 0, "AD-02 r7: a request still in flight must not wake the cache observer — got \(t39Wakes)")
		Adapty.releaseHeldPaywall(.success(AdaptyPaywall()))
		check(t39Wakes == 1, "AD-02 r7: a loaded paywall must wake the cache observer exactly once — got \(t39Wakes)")

		// T39b — the same observer, the branch where no paywall ever arrives. `.unavailable` is only
		// useful if somebody is told to go and read it.
		reset("T39b")
		Adapty.getPaywallResults = [.failure(AdaptyError(.badRequest))]
		let t39b = AdaptyService()
		var t39bWakes = 0
		t39b.observer = { t39bWakes += 1 }
		t39b.configure(apiKey: key, customerUserId: "u1", sessionsCounter: 1, placements: ["typo"], analytics: FakeAnalytics(), attStatus: .notDetermined)
		check(t39bWakes == 1, "AD-02 r7: a placement Adapty rejected must wake the observer too, or the screen never leaves the spinner — got \(t39bWakes)")
		check(t39b.paywallState(placement: "typo") == .unavailable, "AD-02 r7: the state the wake sends the screen to read must be .unavailable, got \(t39b.paywallState(placement: "typo"))")

		// T40 — AD-03 row 6: a failed listing must not be cached. The schema tells the caller to show
		// "try again later" and allow the retry, which is a promise only if the retry actually reaches
		// the store — a `.failed` remembered as an empty list would answer the same way forever, and
		// the difference is invisible from the answer alone.
		reset("T40")
		Adapty.getPaywallResults = [.success(AdaptyPaywall())]
		Adapty.getPaywallProductsResult = .failure(AdaptyError(.noProductIDsFound))
		let t40 = AdaptyService()
		t40.configure(apiKey: key, customerUserId: "u1", sessionsCounter: 1, placements: ["main"], analytics: FakeAnalytics(), attStatus: .notDetermined)
		let t40Failed = run { await t40.products(placement: "main") }
		check(name(t40Failed ?? .notReady) == "failed", "AD-03 r6 setup: the first call must answer .failed, got \(name(t40Failed ?? .notReady))")
		let t40Before = Adapty.getPaywallProductsCallCount
		Adapty.getPaywallProductsResult = .success([AdaptyPaywallProduct(vendorProductId: "year.sub")])
		let t40Retry = run { await t40.products(placement: "main") }
		check(Adapty.getPaywallProductsCallCount == t40Before + 1, "AD-03 r6: a failed listing must not be cached — the retry must reach the SDK again — \(t40Before) → \(Adapty.getPaywallProductsCallCount)")
		check(name(t40Retry ?? .notReady) == "products(1)", "AD-03 r6: the retry must be applied, not merely attempted, got \(name(t40Retry ?? .notReady))")

		// T41 — AD-04 row 8: exactly one verdict per call. The schema says it twice — "one verdict per
		// call" in the steady state, "the caller, exactly once per call" in the side-effect table — and
		// a second `resume` on a continuation is a hard crash, not a dropped value. AD-04's "what was
		// checked" records that the Adapty 2.10.4 pin does not double-call through this path, so the
		// guard is insurance; this is the check that the insurance works, and it is the only place in
		// the package where a double answer can be produced at all.
		reset("T41")
		Adapty.getPaywallResults = [.success(AdaptyPaywall())]
		Adapty.getPaywallProductsResult = .success([AdaptyPaywallProduct(vendorProductId: "year.sub")])
		let t41 = AdaptyService(deadlines: fast(\.purchase, 5))
		t41.configure(apiKey: key, customerUserId: "u1", sessionsCounter: 1, placements: ["main"], analytics: FakeAnalytics(), attStatus: .notDetermined)
		Adapty.holdMakePurchase = true
		// `heldPurchases` is deliberately never cleared by `reset()` — see the stub — so the count is
		// taken here rather than assumed to start at zero.
		let t41Held = Adapty.heldPurchases.count
		var t41Verdicts: [String] = []
		Task { t41Verdicts.append(name(await t41.buy(productId: "year.sub", placement: "main"))) }
		check(wait(3) { Adapty.heldPurchases.count > t41Held }, "AD-04 r8 setup: the purchase must reach the SDK and be held")
		let t41Callback = Adapty.heldPurchases.last
		t41Callback?(.success(()))
		t41Callback?(.failure(AdaptyError(.paymentCancelled)))
		check(wait(3) { !t41Verdicts.isEmpty }, "AD-04 r8: the call must settle after the SDK's first answer")
		check(t41Verdicts == ["success"], "AD-04 r8: an SDK that answers twice must still yield exactly one verdict, and it must be the first — got \(t41Verdicts)")
		check(hasLog("fired more than once"), "AD-04 r8: the dropped second answer must leave a trace, or a real double callback stays silent — got \(log)")

		// T42 — AD-05 row 6: `profile()` is the second way the provenance flag flips, and the one
		// nothing pinned. T25 covers the delegate's own half. This half decides what the push AFTER a
		// request means: an answered request says the network has spoken, so the next push is checked;
		// silence must leave the flag down, or a stale "no premium" from disk arrives dressed as a
		// verified denial and PM-06 row 5 stops being true.
		reset("T42")
		Adapty.getPaywallResults = [.success(AdaptyPaywall())]
		Adapty.getProfileResult = .success(AdaptyProfile(accessLevels: [:]))
		let t42 = AdaptyService()
		var t42Pushes: [Bool] = []
		t42.premiumObserver = { _, isVerified in t42Pushes.append(isVerified) }
		t42.configure(apiKey: key, customerUserId: "u1", sessionsCounter: 1, placements: ["main"], analytics: FakeAnalytics(), attStatus: .notDetermined)
		_ = run { await t42.profile() }
		t42.didLoadLatestProfile(AdaptyProfile(accessLevels: [:]))
		check(t42Pushes == [true], "AD-05 r6: a push after an answered profile() must be verified — got \(t42Pushes)")

		// T42b — the same push after a request the SDK never answered. The verdict must stay unverified,
		// which is what keeps a disk profile from closing access.
		reset("T42b")
		Adapty.getPaywallResults = [.success(AdaptyPaywall())]
		Adapty.holdGetProfile = true
		let t42b = AdaptyService(deadlines: fast(\.call, 0.3))
		var t42bPushes: [Bool] = []
		t42b.premiumObserver = { _, isVerified in t42bPushes.append(isVerified) }
		t42b.configure(apiKey: key, customerUserId: "u1", sessionsCounter: 1, placements: ["main"], analytics: FakeAnalytics(), attStatus: .notDetermined)
		_ = run { await t42b.profile() }
		t42b.didLoadLatestProfile(AdaptyProfile(accessLevels: [:]))
		check(t42bPushes == [false], "AD-05 r6: a push after a profile() the SDK never answered must stay unverified — got \(t42bPushes)")

		// T42c — and the third path to the same place: the SDK answered, with an error. `profile()`
		// hands back a double optional there (`.some(nil)`), which is the shape most easily mistaken
		// for an answer.
		reset("T42c")
		Adapty.getPaywallResults = [.success(AdaptyPaywall())]
		Adapty.getProfileResult = .failure(AdaptyError(.serverError))
		let t42c = AdaptyService()
		var t42cPushes: [Bool] = []
		t42c.premiumObserver = { _, isVerified in t42cPushes.append(isVerified) }
		t42c.configure(apiKey: key, customerUserId: "u1", sessionsCounter: 1, placements: ["main"], analytics: FakeAnalytics(), attStatus: .notDetermined)
		_ = run { await t42c.profile() }
		t42c.didLoadLatestProfile(AdaptyProfile(accessLevels: [:]))
		check(t42cPushes == [false], "AD-05 r6: a push after a profile() the SDK refused must stay unverified — got \(t42cPushes)")

		// T43 — AD-07 row 4, the half T37 leaves open. The row asks for an `info` line naming the
		// placement on success as well; a check that only pins the failure line stays green if the
		// success branch goes silent, and then "the impression was sent" is once again unreadable.
		reset("T43")
		let t43 = loadedService()
		t43.logPaywallOpen(placement: "main")
		check(hasLog("logShowPaywall ok for 'main'"), "AD-07 r4: a delivered impression must leave an info line naming the placement — got \(log)")

		testRun()
	}

	// MARK: - AD-01 row 1: the app's own test-run key.

	/// Appended at the end of the file, and called from the end of the section above rather than
	/// added to `sections` — every assert coordinate the AD-01…AD-07 risk tables quote sits between
	/// here and the top, and renumbering them is a worse defect than a long file.
	static func testRun() {
		// T44 — AD-01 row 1: a test run must not stand Adapty up. The app decides what a test run
		// is (`-uitest` among the arguments, or `XCTestConfigurationFilePath` in the environment)
		// and says so with `isTestsRunning`; the package never guesses. Until this key existed the
		// layer activated unconditionally, so every UI-test run of the app went into the live Adapty
		// project with the live key — real profiles, real attribution, real numbers.
		//
		// The reason has to be its own. An app shipped without monetisation and a test run land in
		// the same state, but they are different facts and are cured differently, so a single
		// "empty key" line for both would send whoever reads it to the wrong place.
		reset("T44")
		let t44 = AdaptyService()
		t44.configure(apiKey: key, customerUserId: "u1", sessionsCounter: 1, placements: ["main"], analytics: FakeAnalytics(), attStatus: .notDetermined, isTestsRunning: true)
		check(Adapty.activateCallCount == 0, "AD-01 r1: a test run must not reach Adapty.activate — got \(Adapty.activateCallCount) activation(s)")
		check(t44.isActive == false, "AD-01 r1: a test run must leave the layer inactive")
		check(Adapty.getPaywallCallCount == 0, "AD-01 r1: a test run must not warm any paywall — got \(Adapty.getPaywallCallCount) getPaywall call(s)")
		check(hasIssue("test run"), "AD-01 r1: a test run must record its own reason, apart from the empty-key one — got \(issues())")

		// T44b — the same key set to false, on the same live-shaped key. A guard that is always on
		// proves nothing: this is the assert that goes red if the flag is ever read inverted, and
		// the one that stops "silence the SDK" from quietly becoming "silence it always".
		reset("T44b")
		Adapty.getPaywallResults = [.success(AdaptyPaywall())]
		let t44b = AdaptyService()
		t44b.configure(apiKey: key, customerUserId: "u1", sessionsCounter: 1, placements: ["main"], analytics: FakeAnalytics(), attStatus: .notDetermined, isTestsRunning: false)
		check(Adapty.activateCallCount == 1, "AD-01 r1: isTestsRunning false must still activate the layer — got \(Adapty.activateCallCount) activation(s)")
		check(t44b.isActive, "AD-01 r1: isTestsRunning false must leave the layer active")
	}
}
