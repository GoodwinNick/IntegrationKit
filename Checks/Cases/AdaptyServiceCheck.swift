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
//  Rewritten for Adapty 4.1.3 (release 0.3.0, step 3). What moved:
//    `getPaywall` → `getFlow`, `AdaptyPaywall` → `AdaptyFlow`, one `remoteConfig` → `remoteConfigs`
//    per locale, `logShowPaywall` → `logShowFlow`, `makePurchase` → `AdaptyPurchaseResult` instead of
//    an error table, `updateAttribution` → the pair `updateExternalAttribution` +
//    `setIntegrationIdentifier`, and the amplitude ids off the profile builder onto the second half
//    of that pair.
//
//  Deliberately without a test, per the schemas:
//    AD-01 r5 (partly), AD-03 r4, AD-03 r5, AD-05 r3 — SDK or harness boundary;
//    AD-04 r7, AD-06 r4 — dead code, closed by deletion, which this file cannot assert;
//    AD-07 r3 — closed by a deprecated no-op; the onboarding event does not exist on 4.1.3 at all.
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

	/// `PurchaseVerdict` carries no `Equatable` conformance (nothing in `Sources/` needs one), so
	/// rows about a verdict compare its name.
	///
	/// `paidUnconfirmed` is gone as of AD-04 row 9: on 2.10.x it was the verdict for codes 2004 and
	/// 2005, which cover a network that died BEFORE the payment as well as after it — so it granted
	/// premium to someone who never paid. 4.1.3 answers a completed purchase with
	/// `AdaptyPurchaseResult.success`, and that is now the only thing that means "paid".
	static func name(_ verdict: PurchaseVerdict?) -> String {
		guard let verdict else { return "nil" }
		switch verdict {
			case .success: return "success"
			case .cancelled: return "cancelled"
			case .pending: return "pending"
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

	/// A purchase that went through, in the shape 4.1.3 answers with.
	static func purchased() -> Result<AdaptyPurchaseResult, AdaptyError> {
		.success(.success(profile: AdaptyProfile(accessLevels: [:]), transaction: AdaptyPurchaseResult.SignedTransaction()))
	}

	/// One locale's worth of remote config, which is all most rows need.
	static func config(_ dictionary: [String: Any], locale: String = "en") -> AdaptyRemoteConfig {
		AdaptyRemoteConfig(locale: locale, dictionary: dictionary)
	}

	/// A configured, active service with one loaded placement — the starting state most rows need.
	/// `products` is what `getPaywallProducts` will answer with.
	static func loadedService(
		placement: String = "main",
		remoteConfigs: [AdaptyRemoteConfig] = [],
		products: [AdaptyPaywallProduct] = [AdaptyPaywallProduct(vendorProductId: "year.sub")]
	) -> AdaptyService {
		Adapty.getFlowResults = [.success(AdaptyFlow(remoteConfigs: remoteConfigs))]
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
			("AD-02 placements", placements),
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
		// building the configuration runs `assert(apiKey.count >= 41 && apiKey.starts(with:
		// "public_live"))` on the caller's own stack (`AdaptyConfiguration.Builder.swift:14`), so
		// reaching it takes a DEBUG build down. The stub deliberately does not reproduce that assert,
		// so this proves OUR guard — the assert itself was read in the SDK sources. The process being
		// alive at the end of the row is half the assertion.
		reset("T01")
		let t01 = AdaptyService()
		t01.configure(apiKey: "", customerUserId: "u1", sessionsCounter: 1, placements: ["main"], analytics: FakeAnalytics(), attStatus: .notDetermined)
		check(Adapty.activateCallCount == 0, "AD-01 r1/r7: an empty key must not reach Adapty.activate — got \(Adapty.activateCallCount) activation(s)")
		check(t01.isActive == false, "AD-01 r1/r7: an empty key must leave the layer inactive")
		check(hasIssue("inactive"), "AD-01 r1/r7: an empty key must be recorded as a configuration issue — got \(issues())")

		// T01b — AD-01 row 7, the half an empty key does not reach: a key that is present but is not
		// an Adapty key. The SDK's assert fires on the shape, not on emptiness, so an obfuscated key
		// decrypted wrong trips it just as hard. Both values the schema names are asserted — the SDK
		// stayed untouched, and the reason says what was expected.
		reset("T01b")
		let t01b = AdaptyService()
		t01b.configure(apiKey: "sk_live_not_an_adapty_key_but_long_enough_to_pass_41", customerUserId: "u1", sessionsCounter: 1, placements: ["main"], analytics: FakeAnalytics(), attStatus: .notDetermined)
		check(Adapty.activateCallCount == 0, "AD-01 r7: a key that is not an Adapty key must not reach Adapty.activate — got \(Adapty.activateCallCount) activation(s)")
		check(t01b.isActive == false, "AD-01 r7: a malformed key must leave the layer inactive")
		check(hasIssue("beginning with 'public_live'"), "AD-01 r7: the reason must name the expected shape — got \(issues())")

		// T01c — AD-01, new on 4.1.3: Adapty Attribution. `adaptyAttributionEnabled` is a switch that
		// makes the SDK register the install with Adapty's own attribution service, and it is off by
		// default upstream (`AdaptyConfiguration.swift:16`). The package must leave it off unless the
		// integrator says otherwise: an app that already runs AppsFlyer would otherwise start sending
		// a second, independent install signal that nobody in the app asked for.
		//
		// Both directions are asserted. "Off by default" alone stays green on a parameter that is
		// ignored; the second half proves the switch is actually wired to the builder.
		reset("T01c")
		Adapty.getFlowResults = [.success(AdaptyFlow())]
		let t01c = AdaptyService()
		t01c.configure(apiKey: key, customerUserId: "u1", sessionsCounter: 1, placements: ["main"], analytics: FakeAnalytics(), attStatus: .notDetermined)
		check(Adapty.lastConfiguration?.adaptyAttributionEnabled == false, "AD-01: Adapty Attribution must be off unless asked for — got \(String(describing: Adapty.lastConfiguration?.adaptyAttributionEnabled))")
		check(Adapty.lastConfiguration?.observerMode == false, "AD-01: observer mode must stay off, or the SDK stops watching the transaction queue entirely — got \(String(describing: Adapty.lastConfiguration?.observerMode))")

		reset("T01d")
		Adapty.getFlowResults = [.success(AdaptyFlow())]
		let t01d = AdaptyService()
		t01d.configure(apiKey: key, customerUserId: "u1", sessionsCounter: 1, placements: ["main"], analytics: FakeAnalytics(), attStatus: .notDetermined, adaptyAttributionEnabled: true)
		check(Adapty.lastConfiguration?.adaptyAttributionEnabled == true, "AD-01: an integrator who asks for Adapty Attribution must get it — got \(String(describing: Adapty.lastConfiguration?.adaptyAttributionEnabled))")

		// T02 — AD-01 row 2: analytics has no device id yet. An empty string must NOT be written:
		// it looks like an id and joins this profile to nothing forever. On 4.1.3 the amplitude ids no
		// longer travel on the profile builder — `with(amplitudeDeviceId:)` is gone and they go
		// through `setIntegrationIdentifier` — so the journal that must stay empty is the new one.
		reset("T02")
		Adapty.getFlowResults = [.success(AdaptyFlow())]
		let t02 = AdaptyService()
		t02.configure(apiKey: key, customerUserId: "u1", sessionsCounter: 1, placements: ["main"], analytics: FakeAnalytics(deviceId: nil), attStatus: .notDetermined)
		let t02Written = Adapty.integrationIdentifierJournal.filter { $0.key == .amplitudeDeviceId }.map(\.value)
		check(t02Written.isEmpty, "AD-01 r2: with no analytics device id, amplitudeDeviceId must not be written at all — got \(t02Written)")
		check(hasIssue("no device id"), "AD-01 r2: the missing device id must be recorded — got \(issues())")
		let t02User = Adapty.integrationIdentifierJournal.filter { $0.key == .amplitudeUserId }.map(\.value)
		check(t02User == ["u1"], "AD-01 r2: amplitudeUserId must still be linked — got \(t02User)")

		// T03 — AD-01 row 3: `configure` twice. The SDK rejects the second activation itself
		// (`activateOnceError`, 3005) — what must not happen is the layer carrying on with the REST
		// of the configuration: a second delegate, a second identity write, a second warm-up. The
		// two counters named here are the ones that would grow; asserting "exactly one activation"
		// would only be testing the SDK's own guard.
		reset("T03")
		Adapty.getFlowResults = [.success(AdaptyFlow())]
		Adapty.activateErrors = [nil, AdaptyError(.activateOnceError)]
		let t03 = AdaptyService()
		t03.configure(apiKey: key, customerUserId: "u1", sessionsCounter: 1, placements: ["main"], analytics: FakeAnalytics(), attStatus: .notDetermined)
		let t03Flows = Adapty.getFlowCallCount
		let t03Writes = Adapty.updateProfileJournal.count
		t03.configure(apiKey: key, customerUserId: "u1", sessionsCounter: 1, placements: ["main"], analytics: FakeAnalytics(), attStatus: .notDetermined)
		check(Adapty.getFlowCallCount == t03Flows, "AD-01 r3: a rejected second activation must not warm placements again — \(t03Flows) → \(Adapty.getFlowCallCount)")
		check(Adapty.updateProfileJournal.count == t03Writes, "AD-01 r3: a rejected second activation must not rewrite the profile — \(t03Writes) → \(Adapty.updateProfileJournal.count)")
		check(hasIssue("activate was rejected"), "AD-01 r3: a rejected activation must be recorded — got \(issues())")

		// T04 — AD-01 row 4 / AD-02 row 3: `refreshPaywalls` fires while the first request is still
		// in flight. The stub holds the answer, so the request genuinely has not finished. The SDK
		// de-duplicates nothing (it opens a task per call), so the second request must be suppressed
		// here or not at all.
		reset("T04")
		Adapty.holdGetFlow = true
		let t04 = AdaptyService()
		t04.configure(apiKey: key, customerUserId: "u1", sessionsCounter: 1, placements: ["main"], analytics: FakeAnalytics(), attStatus: .notDetermined)
		t04.refreshPaywalls()
		t04.refreshPaywalls()
		check(Adapty.getFlowCallCount == 1, "AD-01 r4: a request already in flight must not be duplicated — expected 1 getFlow, got \(Adapty.getFlowCallCount)")

		// T05 — AD-01 row 5: an invalid key produces no error anywhere; the SDK re-creates the
		// profile once every 100 ms forever (its own source carries the `TODO` where the give-up
		// should be). The only symptom this layer can see is that no profile ever arrives, and the
		// schema asks for that to be visible. The deadline is injected so the row runs in half a
		// second.
		reset("T05")
		Adapty.getFlowResults = [.success(AdaptyFlow())]
		let t05 = AdaptyService(deadlines: fast(\.firstProfile, 0.2))
		t05.configure(apiKey: key, customerUserId: "u1", sessionsCounter: 1, placements: ["main"], analytics: FakeAnalytics(), attStatus: .notDetermined)
		wait(1) { hasIssue("no profile") }
		check(hasIssue("no profile"), "AD-01 r5: a profile that never arrives must be recorded — got \(issues())")

		// T05b — the same guard must stay quiet when a profile DID arrive, or the line is noise.
		reset("T05b")
		Adapty.getFlowResults = [.success(AdaptyFlow())]
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

	// MARK: - AD-02: placements.

	static func placements() {
		// T07 — AD-02 row 1: a placement that does not exist answers `badRequest` (2003) and will
		// answer it forever. Retrying it is a typo burning battery for the life of the process. The
		// pair of asserts is the point of the row: the SAME failure with a network code must keep
		// retrying. Timing is not measured — `asyncAfter` is not fast-forwardable in this harness,
		// so the assert names attempt counts.
		reset()
		Adapty.getFlowResults = [.failure(AdaptyError(.badRequest))]
		let t07 = AdaptyService()
		t07.configure(apiKey: key, customerUserId: "u1", sessionsCounter: 1, placements: ["typo"], analytics: FakeAnalytics(), attStatus: .notDetermined)
		wait(1) { Adapty.getFlowCallCount > 1 }
		check(Adapty.getFlowCallCount == 1, "AD-02 r1: badRequest must not be retried — expected exactly 1 getFlow, got \(Adapty.getFlowCallCount)")
		check(hasIssue("has no placement 'typo'"), "AD-02 r1: an unknown placement must be recorded by name — got \(issues())")
		t07.refreshPaywalls()
		check(Adapty.getFlowCallCount == 1, "AD-02 r1: a foreground trigger must not revive a badRequest placement — got \(Adapty.getFlowCallCount)")

		reset()
		Adapty.getFlowResults = [.failure(AdaptyError(.networkFailed))]
		let t07b = AdaptyService()
		t07b.configure(apiKey: key, customerUserId: "u1", sessionsCounter: 1, placements: ["main"], analytics: FakeAnalytics(), attStatus: .notDetermined)
		check(wait(2) { Adapty.getFlowCallCount >= 2 }, "AD-02 r1: networkFailed must keep retrying — expected at least 2 getFlow attempts, got \(Adapty.getFlowCallCount)")
		check(!hasIssue("has no placement"), "AD-02 r1: a network failure is not a configuration issue — got \(issues())")

		// T08 — AD-02 row 2 / AD-03 row 2: the placement arrived, the products did not. Code 1000
		// covers two causes the SDK cannot separate (a paywall with no products, products the store
		// does not know), so AD-02 row 6 requires the code itself in the trace: one cause is fixed in
		// the dashboard, the other in App Store Connect.
		reset()
		Adapty.getFlowResults = [.success(AdaptyFlow())]
		Adapty.getPaywallProductsResult = .failure(AdaptyError(.noProductIDsFound))
		let t08 = AdaptyService()
		t08.configure(apiKey: key, customerUserId: "u1", sessionsCounter: 1, placements: ["main"], analytics: FakeAnalytics(), attStatus: .notDetermined)
		check(t08.failedProductLoads == 1, "AD-02 r2: a failed product load must be counted — expected 1, got \(t08.failedProductLoads)")
		check(hasLog("noProductIDsFound"), "AD-02 r6: the trace must name the SDK code, not just 'no products' — got \(log)")

		// T08b — AD-03, new on 4.1.3: the SDK no longer retries a failed product listing on its own.
		// 2.10.x's `ProductsManager` spent three attempts before answering, which is why AD-02 row 2
		// says "there is nothing left to retry". 4.1.3's `StoreKitProductFetcher` makes one pass, so
		// the retry has to be ours or there is none.
		reset()
		Adapty.getFlowResults = [.success(AdaptyFlow())]
		Adapty.getPaywallProductsResult = .failure(AdaptyError(.networkFailed))
		let t08b = AdaptyService()
		t08b.configure(apiKey: key, customerUserId: "u1", sessionsCounter: 1, placements: ["main"], analytics: FakeAnalytics(), attStatus: .notDetermined)
		check(wait(2) { Adapty.getPaywallProductsCallCount >= 2 }, "AD-03: a product listing that failed on the network must be retried by us — the SDK stopped doing it — got \(Adapty.getPaywallProductsCallCount) attempt(s)")

		// T09 — AD-02 row 4: a placement edited in the dashboard mid-session used to be cached until
		// the process died. With the TTL expired, a foreground trigger reloads it.
		reset()
		Adapty.getFlowResults = [.success(AdaptyFlow())]
		let t09 = AdaptyService(deadlines: fast(\.paywallTTL, 0))
		t09.configure(apiKey: key, customerUserId: "u1", sessionsCounter: 1, placements: ["main"], analytics: FakeAnalytics(), attStatus: .notDetermined)
		let t09First = Adapty.getFlowCallCount
		t09.refreshPaywalls()
		check(Adapty.getFlowCallCount == t09First + 1, "AD-02 r4: a stale placement must be reloaded on the next foreground — \(t09First) → \(Adapty.getFlowCallCount)")

		// T09b — and a fresh one must not be, or every foreground costs a request per placement.
		reset()
		Adapty.getFlowResults = [.success(AdaptyFlow())]
		let t09b = AdaptyService(deadlines: fast(\.paywallTTL, 600))
		t09b.configure(apiKey: key, customerUserId: "u1", sessionsCounter: 1, placements: ["main"], analytics: FakeAnalytics(), attStatus: .notDetermined)
		let t09bFirst = Adapty.getFlowCallCount
		t09b.refreshPaywalls()
		check(Adapty.getFlowCallCount == t09bFirst, "AD-02 r4: a fresh placement must not be reloaded — \(t09bFirst) → \(Adapty.getFlowCallCount)")

		// T10 — AD-02 row 5: three different reasons for "no paywall", three different answers. One
		// boolean cannot tell a screen whether to draw a spinner or an empty state.
		reset()
		Adapty.holdGetFlow = true
		let t10 = AdaptyService()
		t10.configure(apiKey: key, customerUserId: "u1", sessionsCounter: 1, placements: ["main"], analytics: FakeAnalytics(), attStatus: .notDetermined)
		check(t10.paywallState(placement: "main") == .loading, "AD-02 r5: a request in flight must read as .loading, got \(t10.paywallState(placement: "main"))")
		check(t10.paywallState(placement: "never-configured") == .unavailable, "AD-02 r5: a placement nobody configured must read as .unavailable, got \(t10.paywallState(placement: "never-configured"))")
		Adapty.releaseHeldFlow(.success(AdaptyFlow()))
		check(t10.paywallState(placement: "main") == .ready, "AD-02 r5: a loaded placement must read as .ready, got \(t10.paywallState(placement: "main"))")

		// T10b — and the fourth: a placement Adapty rejected is not "loading" either.
		reset()
		Adapty.getFlowResults = [.failure(AdaptyError(.badRequest))]
		let t10b = AdaptyService()
		t10b.configure(apiKey: key, customerUserId: "u1", sessionsCounter: 1, placements: ["typo"], analytics: FakeAnalytics(), attStatus: .notDetermined)
		check(t10b.paywallState(placement: "typo") == .unavailable, "AD-02 r5: a placement Adapty rejected must read as .unavailable, got \(t10b.paywallState(placement: "typo"))")

		// T11 — PM-07 row 8, kept from the previous revision: an always-failing placement retries by
		// itself, and the retries stay spaced. Both bounds come from one sentence of the schema —
		// loading continues until it succeeds, and it must not become a tight loop.
		reset()
		Adapty.getFlowResults = [.failure(AdaptyError(.networkFailed))]
		let t11 = AdaptyService()
		t11.configure(apiKey: key, customerUserId: "u1", sessionsCounter: 1, placements: ["main"], analytics: FakeAnalytics(), attStatus: .notDetermined)
		wait(1) { Adapty.getFlowCallCount >= 5 }
		let t11Count = Adapty.getFlowCallCount
		check(t11.hasPaywall(placement: "main") == false, "PM-07 r8: an always-failing placement must never report hasPaywall true")
		check(t11Count >= 2, "PM-07 r8: a failed load must retry on its own — expected at least 2 attempts within a second, got \(t11Count)")
		check(t11Count <= 5, "PM-07 r8: the retry must stay spaced, never a tight loop — expected at most 5 attempts in that second, got \(t11Count)")

		// T12 — PM-07 row 8: a successful retry is applied, not merely attempted.
		reset()
		Adapty.getFlowResults = [.failure(AdaptyError(.networkFailed)), .success(AdaptyFlow())]
		let t12 = AdaptyService()
		t12.configure(apiKey: key, customerUserId: "u1", sessionsCounter: 1, placements: ["main"], analytics: FakeAnalytics(), attStatus: .notDetermined)
		t12.refreshPaywalls()
		check(t12.hasPaywall(placement: "main") == true, "PM-07 r8: a successful retry must be applied — hasPaywall is still false")
		check(Adapty.getFlowCallCount >= 2, "PM-07 r8: expected at least 2 getFlow attempts, got \(Adapty.getFlowCallCount)")

		// T13 — PM-07 row 8: retry chains must not stack. Four triggers are four immediate attempts,
		// which is correct; what must not follow is four independent chains hammering the SDK.
		reset()
		Adapty.getFlowResults = [.failure(AdaptyError(.networkFailed))]
		let t13 = AdaptyService(deadlines: fast(\.paywallTTL, 0))
		t13.configure(apiKey: key, customerUserId: "u1", sessionsCounter: 1, placements: ["main"], analytics: FakeAnalytics(), attStatus: .notDetermined)
		t13.refreshPaywalls()
		t13.refreshPaywalls()
		t13.refreshPaywalls()
		let t13Immediate = Adapty.getFlowCallCount
		check(t13Immediate == 4, "PM-07 r8: configure plus three foreground triggers must each attempt once — expected 4, got \(t13Immediate)")
		wait(1) { false }
		check(Adapty.getFlowCallCount <= 6, "PM-07 r8: retry chains must not stack per trigger — expected at most 6 attempts a second later, got \(Adapty.getFlowCallCount)")
	}

	// MARK: - AD-03: products.

	static func products() {
		// T14 — AD-03 row 1: two causes, two answers. `count == 0` is identical in both and proves
		// nothing, so the assert names the case.
		reset()
		let t14 = AdaptyService()
		t14.configure(apiKey: key, customerUserId: "u1", sessionsCounter: 1, placements: ["main"], analytics: FakeAnalytics(), attStatus: .notDetermined)
		let t14NoPaywall = run { await t14.products(placement: "main") }
		check(name(t14NoPaywall ?? .failed) == "notReady", "AD-03 r1: with no placement loaded the answer must be .notReady, got \(name(t14NoPaywall ?? .failed))")

		reset()
		Adapty.getFlowResults = [.success(AdaptyFlow())]
		Adapty.getPaywallProductsResult = .failure(AdaptyError(.noProductIDsFound))
		let t14b = AdaptyService()
		t14b.configure(apiKey: key, customerUserId: "u1", sessionsCounter: 1, placements: ["main"], analytics: FakeAnalytics(), attStatus: .notDetermined)
		let t14bFailed = run { await t14b.products(placement: "main") }
		check(name(t14bFailed ?? .notReady) == "failed", "AD-03 r1: with the placement loaded and the listing failing the answer must be .failed, got \(name(t14bFailed ?? .notReady))")

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

		// T16b — AD-03, new on 4.1.3: `introductoryDiscount` is gone. Its replacement,
		// `subscriptionOffer`, carries whichever offer the SDK resolved for this user — introductory,
		// promotional or win-back — and `AdaptySubscriptionOfferType` is a RawRepresentable struct,
		// so the compiler forces nobody to notice. A win-back offer mapped into `introductoryOffer`
		// is a "7 days free, first time only" badge shown to a returning subscriber.
		//
		// Three offers, one assert each, because the failure mode is silent by construction: a
		// mapping that keeps whatever it is handed passes any check that only feeds it an
		// introductory offer.
		let period = AdaptySubscriptionPeriod(unit: .week, numberOfUnits: 1)
		for (type, expected) in [(AdaptySubscriptionOfferType.introductory, true), (.promotional, false), (.winBack, false)] {
			reset()
			let offer = AdaptySubscriptionOffer(offerType: type, subscriptionPeriod: period)
			let service = loadedService(products: [AdaptyPaywallProduct(vendorProductId: "year.sub", subscriptionOffer: offer)])
			let answer = run { await service.products(placement: "main") }
			guard case .products(let list) = answer ?? .notReady, let first = list.first else {
				check(false, "AD-03 setup: expected products for \(type.rawValue), got \(name(answer ?? .notReady))")
				continue
			}
			check((first.introductoryOffer != nil) == expected, "AD-03: only an offerType of .introductory may become introductoryOffer — \(type.rawValue) gave \(first.introductoryOffer == nil ? "nil" : "an offer")")
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
		var t17InactiveResult: PurchaseVerdict?
		t17Inactive.buyProduct(placement: "main", id: "year.sub") { t17InactiveResult = $0 }
		check(name(t17InactiveResult) == "failed", "AD-04 r4: an inactive layer must not fall back to StoreKit — expected .failed, got \(name(t17InactiveResult))")
		check(hasIssue("inactive"), "AD-04 r4: a purchase against an inactive layer must be recorded — got \(issues())")

		reset()
		let t17NoPaywall = AdaptyService()
		t17NoPaywall.configure(apiKey: key, customerUserId: "u1", sessionsCounter: 1, placements: ["main"], analytics: FakeAnalytics(), attStatus: .notDetermined)
		var t17NoPaywallResult: PurchaseVerdict?
		t17NoPaywall.buyProduct(placement: "main", id: "year.sub") { t17NoPaywallResult = $0 }
		check(name(t17NoPaywallResult) == "retryWithStoreKit", "AD-04 r4/PM-04 r8: an unloaded placement must answer .retryWithStoreKit, got \(name(t17NoPaywallResult))")

		reset()
		let t17WrongId = loadedService(products: [AdaptyPaywallProduct(vendorProductId: "year.sub")])
		var t17WrongIdResult: PurchaseVerdict?
		t17WrongId.buyProduct(placement: "main", id: "month.sub") { t17WrongIdResult = $0 }
		check(name(t17WrongIdResult) == "unavailable", "AD-04 r4: an id the loaded placement does not sell must answer .unavailable, got \(name(t17WrongIdResult))")
		check(hasIssue("is not on Adapty placement"), "AD-04 r4: a product the placement does not sell must be recorded — got \(issues())")

		// T18 — AD-04 row 9, the row that inverts what row 2 used to say. On 2.10.x codes 2004 and
		// 2005 mapped to `paidUnconfirmed`, which granted premium: the reasoning was that Apple had
		// charged and Adapty simply could not confirm it. But 2005 is also what a request that never
		// left the device answers with — no payment sheet, no charge — and the two are
		// indistinguishable from the error alone. So the verdict granted premium to a user who never
		// paid, for as long as the local grant lasts.
		//
		// 4.1.3 removes the guesswork: a purchase that completed comes back as
		// `AdaptyPurchaseResult.success`, and an `AdaptyError` means it did not complete. Both codes
		// must now read as an ordinary retryable failure. A real payer whose confirmation was lost is
		// picked up by the profile push and by `restorePurchases` — the paths that KNOW.
		for code in [AdaptyError.ErrorCode.serverError, .networkFailed] {
			reset()
			let service = loadedService()
			Adapty.makePurchaseResult = .failure(AdaptyError(code))
			var result: PurchaseVerdict?
			service.buyProduct(placement: "main", id: "year.sub") { result = $0 }
			check(name(result) == "failed", "AD-04 r9: \(code) must not grant premium on a guess — expected .failed, got \(name(result))")
		}

		// T19 — AD-04 row 3: a promotional offer the store refuses to sign. This fails before any
		// payment is queued, so the fallback would buy the same product at full price, silently,
		// right after the user was shown a discount. The verdict has to differ from the ordinary
		// `retryWithStoreKit`.
		for code in [AdaptyError.ErrorCode.invalidOfferIdentifier, .invalidSignature, .missingOfferParams, .invalidOfferPrice] {
			reset()
			let service = loadedService()
			Adapty.makePurchaseResult = .failure(AdaptyError(code))
			var result: PurchaseVerdict?
			service.buyProduct(placement: "main", id: "year.sub") { result = $0 }
			check(name(result) == "unavailable", "AD-04 r3: an unsigned promotional offer (\(code)) must not silently buy at full price — expected .unavailable, got \(name(result))")
		}

		// T20 — AD-04 row 5: a permanent refusal must not look like a temporary one. Parental
		// controls answer the same way on every retry, so the button should go away instead of
		// failing again.
		for code in [AdaptyError.ErrorCode.cantMakePayments, .paymentNotAllowed, .storeProductNotAvailable] {
			reset()
			let service = loadedService()
			Adapty.makePurchaseResult = .failure(AdaptyError(code))
			var result: PurchaseVerdict?
			service.buyProduct(placement: "main", id: "year.sub") { result = $0 }
			check(name(result) == "unavailable", "AD-04 r5: \(code) is permanent for this device — expected .unavailable, got \(name(result))")
			check(hasIssue("cannot be purchased on this device"), "AD-04 r5: a permanent refusal must be recorded — got \(issues())")
		}
		reset()
		let t20Temp = loadedService()
		Adapty.makePurchaseResult = .failure(AdaptyError(.networkFailed))
		var t20TempResult: PurchaseVerdict?
		t20Temp.buyProduct(placement: "main", id: "year.sub") { t20TempResult = $0 }
		check(name(t20TempResult) != "unavailable", "AD-04 r5: networkFailed is temporary and must not read as a permanent refusal, got \(name(t20TempResult))")

		// T21 — AD-04, rewritten for 4.1.3: a user cancel is no longer an error at all. It arrives as
		// `AdaptyPurchaseResult.userCancelled` inside a SUCCESSFUL result, so a mapping that only
		// looks at the failure branch reports a purchase that never happened as a purchase.
		reset()
		let t21 = loadedService()
		Adapty.makePurchaseResult = .success(.userCancelled)
		var t21Result: PurchaseVerdict?
		t21.buyProduct(placement: "main", id: "year.sub") { t21Result = $0 }
		check(name(t21Result) == "cancelled", "AD-04: userCancelled arrives as a SUCCESS on 4.1.3 and must still map to .cancelled, got \(name(t21Result))")

		// T21b — the third case of the same enum, and the one with money attached: "Ask to Buy"
		// waiting for a parent. Neither bought nor refused, and mapping it to either is wrong — a
		// failure invites a second attempt, a success unlocks premium for a purchase not yet made.
		reset()
		let t21b = loadedService()
		Adapty.makePurchaseResult = .success(.pending)
		var t21bResult: PurchaseVerdict?
		t21b.buyProduct(placement: "main", id: "year.sub") { t21bResult = $0 }
		check(name(t21bResult) == "pending", "AD-04: a pending purchase must map to .pending, got \(name(t21bResult))")

		// T21c — and the one that pays: a completed purchase.
		reset()
		let t21c = loadedService()
		Adapty.makePurchaseResult = purchased()
		var t21cResult: PurchaseVerdict?
		t21c.buyProduct(placement: "main", id: "year.sub") { t21cResult = $0 }
		check(name(t21cResult) == "success", "AD-04: a completed purchase must map to .success, got \(name(t21cResult))")

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
		// never calls back.
		//
		// Two asserts, both required by the row. First: the wait ends in a verdict, and the verdict
		// is WAITING — not a failure the user is invited to retry into a second charge. Second: the
		// machinery is free afterwards, which is the half that mattered most, since one hung purchase
		// used to refuse every later purchase in the process.
		reset()
		Adapty.getFlowResults = [.success(AdaptyFlow())]
		Adapty.getPaywallProductsResult = .success([AdaptyPaywallProduct(vendorProductId: "year.sub")])
		let t23 = AdaptyService(deadlines: fast(\.purchase, 0.3))
		t23.configure(apiKey: key, customerUserId: "u1", sessionsCounter: 1, placements: ["main"], analytics: FakeAnalytics(), attStatus: .notDetermined)
		Adapty.holdMakePurchase = true
		let t23Started = Date()
		let t23Result = run { await t23.buy(productId: "year.sub", placement: "main") }
		check(name(t23Result) == "pending", "AD-04 r1: a purchase the SDK never answers must settle as .pending, got \(name(t23Result))")
		check(Date().timeIntervalSince(t23Started) < 2, "AD-04 r1: it must settle on its own deadline, took \(Date().timeIntervalSince(t23Started))s")

		Adapty.holdMakePurchase = false
		Adapty.makePurchaseResult = purchased()
		let t23Second = run { await t23.buy(productId: "year.sub", placement: "main") }
		check(name(t23Second) == "success", "AD-04 r1: the purchase after a hung one must go through — got \(name(t23Second))")
	}

	// MARK: - AD-05: profile and receipt.

	static func profile() {
		// T24 — AD-05 row 1: `getProfile` is called and never answered. Upstream that is a real
		// state, not a hypothetical: on a first launch whose profile cannot be created the SDK wakes
		// only its other bucket of handlers and retries forever. The assert names the return and the
		// time, not the value — `nil` also comes back from a working call.
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
		Adapty.getFlowResults = [.success(AdaptyFlow())]
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
		//
		// On 4.1.3 the write is a PAIR: the payload goes to `updateExternalAttribution` and the
		// AppsFlyer id, which is what joins the two systems, goes to `setIntegrationIdentifier`. Both
		// halves are asserted, because a queue that repeats only the payload leaves the join key
		// missing and the dashboard still cannot match this user.
		reset()
		Adapty.getFlowResults = [.success(AdaptyFlow())]
		let t28 = AdaptyService()
		t28.updateAppsFlyerAttribution(["af_status": "Organic"], networkUserId: "af-uid-1")
		check(Adapty.externalAttributionJournal.isEmpty, "AD-06 r1 setup: a write before activation must not reach the SDK — got \(Adapty.externalAttributionJournal.count)")
		t28.configure(apiKey: key, customerUserId: "u1", sessionsCounter: 1, placements: ["main"], analytics: FakeAnalytics(), attStatus: .notDetermined)
		let t28Providers = Adapty.externalAttributionJournal.map(\.provider.rawValue)
		check(t28Providers == ["appsflyer"], "AD-06 r1: the queued attribution must be repeated after activation — got \(t28Providers)")
		let t28Ids = Adapty.integrationIdentifierJournal.filter { $0.key == .appsflyerId }.map(\.value)
		check(t28Ids == ["af-uid-1"], "AD-06 r1: the AppsFlyer id is the join key and must be sent with it — got \(t28Ids)")

		// T28b — AD-06, new on 4.1.3: an EMPTY networkUserId. `AdaptyIntegrationIdentifier` trims its
		// value and does not check for empty (`:17`), so `.appsflyerId("")` writes an empty join key
		// — which the dashboard stores and matches against nothing, permanently. The old
		// `assert(networkUserId != nil)` that used to catch this is gone with the old method.
		reset()
		Adapty.getFlowResults = [.success(AdaptyFlow())]
		let t28b = loadedService()
		t28b.updateAppsFlyerAttribution(["af_status": "Organic"], networkUserId: "   ")
		let t28bIds = Adapty.integrationIdentifierJournal.filter { $0.key == .appsflyerId }.map(\.value)
		check(t28bIds.isEmpty, "AD-06: an empty AppsFlyer id must not be written — an empty join key matches nothing forever — got \(t28bIds)")
		check(hasIssue("AppsFlyer id"), "AD-06: a missing AppsFlyer id must be recorded — got \(issues())")

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
		check(t30bWritten == [.string("summer_sale")], "AD-06 r3: a legal value must reach the SDK — got \(t30bWritten)")

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
		check(Adapty.externalAttributionJournal.isEmpty, "AD-06 r5: an inactive layer must write no attribution — got \(Adapty.externalAttributionJournal.count)")
		check(Adapty.integrationIdentifierJournal.isEmpty, "AD-06 r5: an inactive layer must write no integration id — got \(Adapty.integrationIdentifierJournal.count)")
		check(Adapty.restorePurchasesCallCount == 0, "AD-06 r5: an inactive layer must not sync — got \(Adapty.restorePurchasesCallCount)")
		check(Adapty.logShowFlowJournal.isEmpty, "AD-06 r5: an inactive layer must log no impression — got \(Adapty.logShowFlowJournal.count)")
		check(issues().count == 1, "AD-06 r5: an inactive layer must record ONE line, not one per operation — got \(issues())")

		// T32 — AD-06 row 6: the ATT status is state, not install data. The SDK still does not resend
		// it by itself on 4.1.3 — `Environment.Meta` reads the status but never encodes it, and the
		// Meta block goes out once per profile — so every launch has to send the current value. Two
		// launches with DIFFERENT answers, and the assert names both values: "two writes happened"
		// would stay green if the second launch resent the first launch's stale status.
		reset("T32")
		Adapty.getFlowResults = [.success(AdaptyFlow())]
		let t32 = AdaptyService()
		t32.configure(apiKey: key, customerUserId: "u1", sessionsCounter: 1, placements: ["main"], analytics: FakeAnalytics(), attStatus: .denied)
		let t32First = Adapty.updateProfileJournal.compactMap(\.attStatus)
		check(t32First == [.denied], "AD-06 r6: configure must send the current ATT status — got \(t32First)")
		let t32Second = AdaptyService()
		t32Second.configure(apiKey: key, customerUserId: "u2", sessionsCounter: 2, placements: ["main"], analytics: FakeAnalytics(), attStatus: .authorized)
		let t32Both = Adapty.updateProfileJournal.compactMap(\.attStatus)
		check(t32Both == [.denied, .authorized], "AD-06 r6: the next launch must send the CURRENT status again, not the first one — got \(t32Both)")

		// T32b — AD-06 row 9, the row the migration created. On 2.10.x a write made before activation
		// finished failed at once with `notActivated` (2002), and that failure is what put the write
		// on the retry queue. On 4.1.3 `Adapty.activatedSDK` AWAITS an activation that is in flight
		// (`Adapty+Shared.swift:32-44`), so the same write does not fail — it hangs, with no error, no
		// queue entry and no trace. An activation that never finishes (a wrong key, a dead network on
		// first launch) therefore swallows the install attribution silently.
		//
		// The queue's feeder has to become a DEADLINE. The assert names the trace, because the write
		// itself is legitimately still outstanding — what must not happen is that nobody is told.
		reset("T32b")
		Adapty.activationNeverFinishes = true
		let t32b = AdaptyService(deadlines: fast(\.write, 0.2))
		t32b.configure(apiKey: key, customerUserId: "u1", sessionsCounter: 1, placements: ["main"], analytics: FakeAnalytics(), attStatus: .notDetermined)
		t32b.updateAppsFlyerAttribution(["af_status": "Non-organic"], networkUserId: "af-uid-9")
		wait(1) { hasIssue("never answered") }
		check(hasIssue("never answered"), "AD-06 r9: an activation that never finishes must not swallow the write in silence — got \(issues())")

		// T32c — and the other half of row 9: the write must still be repeated once the SDK comes
		// back. A deadline that only logs turns a lost write into a logged lost write.
		Adapty.releaseActivation()
		wait(1) { !Adapty.externalAttributionJournal.isEmpty }
		let t32cIds = Adapty.integrationIdentifierJournal.filter { $0.key == .appsflyerId }.map(\.value)
		check(t32cIds == ["af-uid-9"], "AD-06 r9: a write held by a slow activation must still land once activation completes — got \(t32cIds)")

		// T32d — AD-06 row 10: the composite write, one half failing. The payload and the join key are
		// two independent calls now, so "attribution was sent" has two answers. A half-write is worse
		// than no write: the dashboard has campaign data it cannot attach to a user, or a user id with
		// no campaign behind it, and neither state is visible from the app.
		reset("T32d")
		Adapty.getFlowResults = [.success(AdaptyFlow())]
		let t32d = loadedService()
		Adapty.integrationIdentifierError = AdaptyError(.networkFailed)
		t32d.updateAppsFlyerAttribution(["af_status": "Non-organic"], networkUserId: "af-uid-10")
		check(hasIssue("attribution"), "AD-06 r10: a half-written attribution must be recorded — got \(issues())")
		Adapty.integrationIdentifierError = nil
		t32d.refreshPaywalls()
		let t32dIds = Adapty.integrationIdentifierJournal.filter { $0.key == .appsflyerId }.map(\.value)
		check(t32dIds == ["af-uid-10"], "AD-06 r10: the half that failed must be retried at the next foreground pass — got \(t32dIds)")
		let t32dPayloads = Adapty.externalAttributionJournal.count
		check(t32dPayloads == 1, "AD-06 r10: the half that succeeded must NOT be sent twice — got \(t32dPayloads) payload write(s)")

		// T32e — AD-06 row 11: a payload that will not serialise. `updateExternalAttribution` runs
		// `JSONSerialization` FIRST and calls the completion synchronously, on the caller's own stack,
		// with `wrongParam` (`Adapty+Completion.swift:137-144`). A retry queue that re-queues on any
		// failure therefore re-queues from inside its own drain, and does it again on every foreground
		// pass, forever — the payload will never serialise, because it is the payload that is wrong.
		//
		// `Date` is the live case, not a contrived one: AppsFlyer conversion dictionaries carry
		// `install_time` values that arrive as `Date` on some SDK versions.
		reset("T32e")
		Adapty.getFlowResults = [.success(AdaptyFlow())]
		let t32e = loadedService()
		t32e.updateAppsFlyerAttribution(["install_time": Date()], networkUserId: "af-uid-11")
		check(Adapty.externalAttributionJournal.isEmpty, "AD-06 r11 setup: an unserialisable payload cannot reach the SDK — got \(Adapty.externalAttributionJournal.count)")
		check(hasIssue("could not be encoded"), "AD-06 r11: an unserialisable payload must be recorded, not silently requeued — got \(issues())")
		t32e.refreshPaywalls()
		t32e.refreshPaywalls()
		check(!hasLog("retrying attribution"), "AD-06 r11: wrongParam is permanent and must never be retried — got \(log)")
	}

	// MARK: - AD-07: remote values and impressions.

	static func remoteValues() {
		// T33 — AD-07 row 1: four causes that used to be one `nil`. `nil` comes back in all four
		// today and proves nothing, so every assert names the case.
		reset()
		Adapty.holdGetFlow = true
		let t33NoPaywall = AdaptyService()
		t33NoPaywall.configure(apiKey: key, customerUserId: "u1", sessionsCounter: 1, placements: ["main"], analytics: FakeAnalytics(), attStatus: .notDetermined)
		let t33A: RemoteValue<Int> = t33NoPaywall.getRemoteValue(placement: "main", key: "count")
		check(name(t33A) == "notReady", "AD-07 r1: a placement that has not arrived must read as .notReady, got \(name(t33A))")

		reset()
		let t33NoConfig = loadedService(remoteConfigs: [])
		let t33B: RemoteValue<Int> = t33NoConfig.getRemoteValue(placement: "main", key: "count")
		check(name(t33B) == "noConfig", "AD-07 r1: a placement with no remote config must read as .noConfig, got \(name(t33B))")

		reset()
		let t33Config = loadedService(remoteConfigs: [config(["count": 42])])
		let t33C: RemoteValue<Int> = t33Config.getRemoteValue(placement: "main", key: "missing")
		check(name(t33C) == "notSet", "AD-07 r1: a key the config does not carry must read as .notSet, got \(name(t33C))")
		let t33D: RemoteValue<String> = t33Config.getRemoteValue(placement: "main", key: "count")
		check(name(t33D) == "wrongType", "AD-07 r1: a value of another type must read as .wrongType, got \(name(t33D))")
		check(hasIssue("'count' on 'main'"), "AD-07 r1: a dashboard type mismatch must be recorded with the key — got \(issues())")
		let t33E: RemoteValue<Int> = t33Config.getRemoteValue(placement: "main", key: "count")
		check(name(t33E) == "value(42)", "AD-07 r1: the right-typed read must still work, got \(name(t33E))")

		// T33f — AD-07 row 6, new on 4.1.3: `remoteConfigs` is an ARRAY, one entry per locale, and
		// `getFlow` has no `locale:` parameter to narrow it with (`getOnboarding` does —
		// `Adapty+Completion.swift:192-207` — `getFlow` at `:177-190` does not). So the choice is
		// ours. Taking `.first` means the dashboard's row order decides which language a paywall
		// speaks, and reordering two rows in a web UI silently reconfigures the app.
		//
		// Two asserts: the value must come from the DEVICE's locale when one matches, and a fallback
		// to another locale must say so — a paywall quietly rendering in the wrong language is a bug
		// nobody reports and everybody sees.
		reset("T33f")
		let t33f = loadedService(remoteConfigs: [
			config(["title": "Hallo"], locale: "de"),
			config(["title": "Hello"], locale: "en"),
		])
		let t33fValue: RemoteValue<String> = t33f.getRemoteValue(placement: "main", key: "title", locale: "en")
		check(name(t33fValue) == "value(Hello)", "AD-07 r6: the config of the asked-for locale must win, not the first row in the dashboard — got \(name(t33fValue))")

		reset("T33g")
		let t33g = loadedService(remoteConfigs: [config(["title": "Hallo"], locale: "de")])
		let t33gValue: RemoteValue<String> = t33g.getRemoteValue(placement: "main", key: "title", locale: "fr")
		check(name(t33gValue) == "value(Hallo)", "AD-07 r6: with no matching locale the read must still answer rather than fail — got \(name(t33gValue))")
		check(hasIssue("locale"), "AD-07 r6: a fallback to another locale must be recorded — got \(issues())")

		// T34 — AD-07 row 5: the SDK's `dictionary` re-runs JSONSerialization on every access, and a
		// paywall screen reads a handful of keys while it lays itself out. Three reads, one parse.
		reset()
		let t34 = loadedService(remoteConfigs: [config(["a": 1, "b": 2, "c": 3])])
		let t34Baseline = AdaptyRemoteConfig.parseCount
		let _: RemoteValue<Int> = t34.getRemoteValue(placement: "main", key: "a")
		let _: RemoteValue<Int> = t34.getRemoteValue(placement: "main", key: "b")
		let _: RemoteValue<Int> = t34.getRemoteValue(placement: "main", key: "c")
		check(AdaptyRemoteConfig.parseCount == t34Baseline, "AD-07 r5: reading three keys must not re-parse the config — \(t34Baseline) → \(AdaptyRemoteConfig.parseCount) parses")
		check(t34Baseline >= 1, "AD-07 r5 setup: the config must have been parsed once at load time, got \(t34Baseline)")

		// T35 — AD-07 row 2 / PM-07 row 10: an impression for a placement that is not loaded. Nothing
		// can be sent (there is no variationId), but a purchase can still happen through the
		// fallback, so the skipped impression must leave a trace instead of nothing.
		reset()
		let t35 = AdaptyService()
		t35.configure(apiKey: key, customerUserId: "u1", sessionsCounter: 1, placements: ["main"], analytics: FakeAnalytics(), attStatus: .notDetermined)
		t35.logPaywallOpen(placement: "main")
		check(Adapty.logShowFlowJournal.isEmpty, "AD-07 r2: no placement means no impression can be sent — got \(Adapty.logShowFlowJournal)")
		check(hasLog("impression not counted"), "AD-07 r2: a skipped impression must leave a trace — got \(log)")

		// T36 — PM-07 row 10, the positive: a loaded placement logs exactly one impression, for the
		// variation it actually holds. `logShowFlow` needs nothing from the flow but `variationId`
		// (`Events/Adapty+Events.swift:101-111`), which is also the only value the dashboard funnel
		// is keyed on — so the assert names it rather than a count.
		reset()
		Adapty.getFlowResults = [.success(AdaptyFlow(variationId: "var-7"))]
		Adapty.getPaywallProductsResult = .success([AdaptyPaywallProduct(vendorProductId: "year.sub")])
		let t36 = AdaptyService()
		t36.configure(apiKey: key, customerUserId: "u1", sessionsCounter: 1, placements: ["main"], analytics: FakeAnalytics(), attStatus: .notDetermined)
		t36.logPaywallOpen(placement: "main")
		check(Adapty.logShowFlowJournal == ["var-7"], "PM-07 r10: a loaded placement must log exactly one impression, for its own variation — got \(Adapty.logShowFlowJournal)")

		// T37 — AD-07 row 4: the event call used to discard the SDK's completion, so a dropped
		// impression looked exactly like a sent one.
		reset()
		let t37 = loadedService()
		Adapty.logShowFlowError = AdaptyError(.networkFailed)
		t37.logPaywallOpen(placement: "main")
		check(hasLog("logShowFlow failed for 'main'"), "AD-07 r4: a failed impression must leave an error line naming the placement — got \(log)")

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
		// T39 — AD-02 row 7: the placement-cache observer. The schema's side-effect table promises the
		// screen is woken on every change of the cache, and AD-02 row 1 promises the same wake for a
		// placement Adapty rejects — a wake with no paywall behind it. Nothing pinned either half, and
		// the second one is the expensive one: without it a typo'd placement leaves the screen on its
		// spinner for the life of the process, which is exactly the state `paywallState` was added to
		// make visible.
		reset("T39")
		Adapty.holdGetFlow = true
		let t39 = AdaptyService()
		var t39Wakes = 0
		t39.observer = { t39Wakes += 1 }
		t39.configure(apiKey: key, customerUserId: "u1", sessionsCounter: 1, placements: ["main"], analytics: FakeAnalytics(), attStatus: .notDetermined)
		check(t39Wakes == 0, "AD-02 r7: a request still in flight must not wake the cache observer — got \(t39Wakes)")
		Adapty.releaseHeldFlow(.success(AdaptyFlow()))
		check(t39Wakes == 1, "AD-02 r7: a loaded placement must wake the cache observer exactly once — got \(t39Wakes)")

		// T39b — the same observer, the branch where no paywall ever arrives. `.unavailable` is only
		// useful if somebody is told to go and read it.
		reset("T39b")
		Adapty.getFlowResults = [.failure(AdaptyError(.badRequest))]
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
		Adapty.getFlowResults = [.success(AdaptyFlow())]
		Adapty.getPaywallProductsResult = .failure(AdaptyError(.noProductIDsFound))
		let t40 = AdaptyService()
		t40.configure(apiKey: key, customerUserId: "u1", sessionsCounter: 1, placements: ["main"], analytics: FakeAnalytics(), attStatus: .notDetermined)
		let t40Failed = run { await t40.products(placement: "main") }
		check(name(t40Failed ?? .notReady) == "failed", "AD-03 r6 setup: the first call must answer .failed, got \(name(t40Failed ?? .notReady))")
		let t40Before = Adapty.getPaywallProductsCallCount
		Adapty.getPaywallProductsResult = .success([AdaptyPaywallProduct(vendorProductId: "year.sub")])
		let t40Retry = run { await t40.products(placement: "main") }
		check(Adapty.getPaywallProductsCallCount > t40Before, "AD-03 r6: a failed listing must not be cached — the retry must reach the SDK again — \(t40Before) → \(Adapty.getPaywallProductsCallCount)")
		check(name(t40Retry ?? .notReady) == "products(1)", "AD-03 r6: the retry must be applied, not merely attempted, got \(name(t40Retry ?? .notReady))")

		// T41 — AD-04 row 8: exactly one verdict per call. The schema says it twice — "one verdict per
		// call" in the steady state, "the caller, exactly once per call" in the side-effect table — and
		// a second `resume` on a continuation is a hard crash, not a dropped value. This is the only
		// place in the package where a double answer can be produced at all.
		reset("T41")
		Adapty.getFlowResults = [.success(AdaptyFlow())]
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
		t41Callback?(purchased())
		t41Callback?(.success(.userCancelled))
		check(wait(3) { !t41Verdicts.isEmpty }, "AD-04 r8: the call must settle after the SDK's first answer")
		check(t41Verdicts == ["success"], "AD-04 r8: an SDK that answers twice must still yield exactly one verdict, and it must be the first — got \(t41Verdicts)")
		check(hasLog("fired more than once"), "AD-04 r8: the dropped second answer must leave a trace, or a real double callback stays silent — got \(log)")

		// T42 — AD-05 row 6: `profile()` is the second way the provenance flag flips, and the one
		// nothing pinned. T25 covers the delegate's own half. This half decides what the push AFTER a
		// request means: an answered request says the network has spoken, so the next push is checked;
		// silence must leave the flag down, or a stale "no premium" from disk arrives dressed as a
		// verified denial and PM-06 row 5 stops being true.
		reset("T42")
		Adapty.getFlowResults = [.success(AdaptyFlow())]
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
		Adapty.getFlowResults = [.success(AdaptyFlow())]
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
		Adapty.getFlowResults = [.success(AdaptyFlow())]
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
		check(hasLog("logShowFlow ok for 'main'"), "AD-07 r4: a delivered impression must leave an info line naming the placement — got \(log)")

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
		check(Adapty.getFlowCallCount == 0, "AD-01 r1: a test run must not warm any placement — got \(Adapty.getFlowCallCount) getFlow call(s)")
		check(hasIssue("test run"), "AD-01 r1: a test run must record its own reason, apart from the empty-key one — got \(issues())")

		// T44b — the same key set to false, on the same live-shaped key. A guard that is always on
		// proves nothing: this is the assert that goes red if the flag is ever read inverted, and
		// the one that stops "silence the SDK" from quietly becoming "silence it always".
		reset("T44b")
		Adapty.getFlowResults = [.success(AdaptyFlow())]
		let t44b = AdaptyService()
		t44b.configure(apiKey: key, customerUserId: "u1", sessionsCounter: 1, placements: ["main"], analytics: FakeAnalytics(), attStatus: .notDetermined, isTestsRunning: false)
		check(Adapty.activateCallCount == 1, "AD-01 r1: isTestsRunning false must still activate the layer — got \(Adapty.activateCallCount) activation(s)")
		check(t44b.isActive, "AD-01 r1: isTestsRunning false must leave the layer active")

		attributionRetry()
	}

	// MARK: - AD-06 row 7: the attribution queue's second exit.

	/// Appended after `testRun()` for the same reason `testRun()` is appended after `amendments()`:
	/// every assert coordinate the AD-01…AD-07 risk tables quote sits above this line.
	static func attributionRetry() {
		// T45 — AD-06 row 7: a write the ALREADY ACTIVE SDK refused. It goes back on the queue
		// (`updateAppsFlyerAttribution`'s failure branch), and `flushPendingAttribution` used to have
		// exactly one caller — the `activate` completion, which by then has already run and will not
		// run again in this process. Install data arrives once per install, so that queue entry stayed
		// where it was until the process died: this payer's campaign is counted organic, and the ROAS
		// the campaign is switched off by is the one with its real payers cut out of it.
		//
		// The assert names the JOURNAL GROWING after the failure, not the queueing — the queueing is
		// there without the fix too (T28 already pins it) and on its own proves nothing. The trigger
		// is `refreshPaywalls()` because that is the method the composition root's
		// `didBecomeActive` observer calls (`IntegrationKit.swift`); this check compiles no UIKit, so
		// the notification itself cannot be posted here.
		reset("T45")
		Adapty.getFlowResults = [.success(AdaptyFlow())]
		let t45 = AdaptyService()
		t45.configure(apiKey: key, customerUserId: "u1", sessionsCounter: 1, placements: ["main"], analytics: FakeAnalytics(), attStatus: .notDetermined)
		Adapty.externalAttributionError = AdaptyError(.networkFailed)
		t45.updateAppsFlyerAttribution(["af_status": "Non-organic"], networkUserId: "af-uid-2")
		check(Adapty.externalAttributionJournal.isEmpty, "AD-06 r7 setup: a write the SDK refused must not be journalled — got \(Adapty.externalAttributionJournal.count)")
		Adapty.externalAttributionError = nil
		t45.refreshPaywalls()
		let t45Providers = Adapty.externalAttributionJournal.map(\.provider.rawValue)
		check(t45Providers == ["appsflyer"], "AD-06 r7: a write the already-active SDK refused must be repeated at the next foreground pass — got \(t45Providers)")

		promotedPurchase()
	}

	// MARK: - AD-04: the delegate method that buys by itself.

	/// Appended after `attributionRetry()` for the reason given there: every assert coordinate the
	/// AD-01…AD-07 risk tables quote sits above this line.
	///
	/// The onboarding section that used to live here is gone. 4.1.3 deleted `logShowOnboarding`
	/// entirely — there is no event to send and no guard to test — so AD-07 row 3 is closed by a
	/// deprecated no-op on the facade instead, and the schema records "no test".
	static func promotedPurchase() {
		// T46 — AD-04, new on 4.1.3: `AdaptyDelegate.didReceivePromotedPurchase` ships a DEFAULT
		// implementation that calls `Adapty.makePurchase(product:)` straight away
		// (`AdaptyDelegate.swift:24-29`). Conforming to the protocol and saying nothing is therefore
		// not neutral — it signs the app up to buy whatever the App Store page promoted, outside
		// `PremiumService`'s single-purchase guard, with no paywall shown, no impression logged and
		// no `PurchaseOutcome` delivered to anybody.
		//
		// The assert names the SDK counter rather than our own: what must not happen is a purchase
		// starting inside the SDK, and only the stub can see that.
		reset("T46")
		Adapty.getFlowResults = [.success(AdaptyFlow())]
		let t46 = AdaptyService()
		t46.configure(apiKey: key, customerUserId: "u1", sessionsCounter: 1, placements: ["main"], analytics: FakeAnalytics(), attStatus: .notDetermined)
		t46.didReceivePromotedPurchase(AdaptyPromotedProduct(vendorProductId: "year.sub"))
		check(Adapty.promotedPurchaseAutoBuyCount == 0, "AD-04: the promoted-purchase default must be overridden — the SDK started \(Adapty.promotedPurchaseAutoBuyCount) purchase(s) nobody asked for")
		check(hasLog("promoted purchase"), "AD-04: a promoted purchase the package refuses must leave a trace — got \(log)")
	}
}
