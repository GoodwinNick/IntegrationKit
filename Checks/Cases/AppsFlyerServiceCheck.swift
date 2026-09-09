//
//  AppsFlyerServiceCheck.swift
//  IntegrationKit
//
//  Written from the approved schemas AF-01…AF-06, not from the code. Thirty-nine asserts carry
//  twenty-four of the thirty-two rows plus AN-03 row 4, whose code lives here rather than in
//  Amplitude's; the eight rows that carry none say why — four in a comment above their block,
//  four (the logging rows of 2026-09-09) in the risk row itself — not with a lookalike assert.
//
//  The last five (T30…T34) came out of the 2026-09-09 schema/code re-check, which found three
//  rules the schemas state and no assert held: what a successful `configure` hands the SDK and in
//  which order (AF-01 row 6), the "unknown" default for an attribution field the SDK did not send
//  (AF-03 row 6), and the URL forward reaching the SDK unchanged (AF-05 row 4).
//
//  All thirty-nine are green. Seventeen of them were written red first, against
//  schemas the wrapper did not satisfy yet, and each one names the behaviour the code had to grow
//  rather than the shape it happened to have:
//    T4  AF-01 row 2 — the ATT wait limit is the app's, not the constant 60.
//    T5  AF-01 row 3 — SDK debug logging follows the app's key, not a hardwired `false`.
//    T6  AF-01 row 5 — a second `configure` does not initialize the SDK a second time.
//    T11 AF-03 row 2 — an empty AppsFlyer UID reaches Adapty as nil, not as "".
//    T13 AF-03 row 3 — the profile property and the event do not contradict each other.
//    T15 AF-04 row 1 — the `-` placeholder stays in the event, never in a profile.
//    T21 AF-05 row 1 — the restoration handler answers even when the SDK never calls back.
//    T22 AF-05 row 2 — one foreign object does not take the whole restoration array with it.
//    T24 AN-03 row 4 — the profile properties the package writes are recognizably its own.
//    T25 AF-02 row 1 — a second foreground return starts a new session.
//    T26 AF-01 row 1 — an empty dev key records a reason a release build can read.
//    T27 AF-04 row 2 — a "found" deep link with no content is counted, not just skipped.
//    T28 AF-05 row 3 — the forwards do not touch an uninitialized SDK and still answer the system.
//    T29 AF-06 row 1 — a failed attribution keeps the error's domain and code.
//    T35 AF-01 row 1 — a test run leaves the layer down, with a reason of its own.
//    T36 AF-01 row 3 — SDK logging rides the app's `isDebug`, the key crash collection uses too.
//  The rest were green from the start — the silent failure callback (T23), the eleven-field
//  deep-link payload (T17), last-attribution-wins (T20) — so no later change can loosen them.
//
//  Built WITHOUT `-D DEBUG` on purpose: every row that asks for "a trace visible outside Xcode"
//  (AF-01 row 1, AF-04 row 2, AF-05 row 3, AF-06 row 1) is measured against exactly the build the
//  user gets. `debugLog` writes nothing at all in this build, so none of those asserts can pass by
//  accident: what they read is `ConfigurationIssues` and a counter on the service, both of which
//  an app can read too.
//
//  This check does not stop at the first failing row: every row runs, every failure is collected,
//  and the summary at the end reports all of them with a non-zero exit code — same shape as
//  `CrashlyticsCheck`. A non-zero exit is now a regression, not the expected outcome.
//  Run:  ./Checks/appsflyer-service-check.sh
//

import AppTrackingTransparency
import AppsFlyerLib
import Foundation
import UIKit

/// Records the two calls `AppsFlyerService` makes on analytics. Everything else is the empty
/// conformance the protocol demands and no row reads.
final class FakeAnalytics: AnalyticsTracking {
	private(set) var events: [(name: String, properties: [String: Any]?)] = []
	private(set) var userProperties: [[String: Any]] = []
	var deviceId: String? = "device-1"

	func logEvent(_ event: String, properties: [String: Any]?) {
		events.append((event, properties))
	}

	func setUserProperties(_ properties: [String: Any]) {
		userProperties.append(properties)
	}

	func setUserId(_ userId: String) {}

	func updateTrackingAuthorization(_ status: ATTrackingManager.AuthorizationStatus) {}
}

/// Records the two calls `AppsFlyerService` makes on Adapty. Everything else is the empty
/// conformance the protocol demands and no row reads.
final class FakeAdapty: AdaptyServicing {
	private(set) var profileValues: [(value: String, key: String)] = []
	private(set) var attributionData: [[AnyHashable: Any]] = []
	/// Kept beside `attributionData` rather than inside it: AF-03 row 2 has to tell "handed over
	/// as nil" from "never handed over", and a tuple field read through `.last?` cannot say that.
	private(set) var attributionNetworkUserIds: [String?] = []

	func configure(
		apiKey: String,
		customerUserId: String,
		sessionsCounter: Int,
		placements: [String],
		analytics: AnalyticsTracking,
		attStatus: ATTrackingManager.AuthorizationStatus, isTestsRunning: Bool,
		adaptyAttributionEnabled: Bool
	) {}

	func setProfileValue(value: String, key: String) {
		profileValues.append((value, key))
	}

	func hasPaywall(placement: String) -> Bool { false }
	func paywallState(placement: String) -> PaywallState { .unavailable }
	func hasProductsForPaywall(placement: String, id: String) -> Bool { false }
	func hasProductsForPaywall(placement: String) -> Bool { false }
	func refreshPaywalls() {}
	func getRemoteValue<Type>(placement: String, key: String, locale: String) -> RemoteValue<Type> { .notReady }
	func logPaywallOpen(placement: String) {}
	func buyProduct(placement: String, id: String, completion: ((PurchaseVerdict) -> Void)?) {}
	func updateAppTrackingTransparencyStatus(_ status: ATTrackingManager.AuthorizationStatus) {}

	func updateAppsFlyerAttribution(_ data: [AnyHashable: Any], networkUserId: String?) {
		attributionData.append(data)
		attributionNetworkUserIds.append(networkUserId)
	}
}

/// AF-05 row 2 needs at least one object that survives the filter at `AppsFlyerService.swift:108`.
/// `UIUserActivityRestoring` carries no requirements, so conforming costs one line.
final class FakeRestorer: UIUserActivityRestoring {}

@main
enum AppsFlyerServiceCheck {
	static var failures: [String] = []

	/// Records a failure instead of trapping — one failing row must not stop every row after it
	/// from running.
	static func check(_ condition: @autoclosure () -> Bool, _ message: @autoclosure () -> String) {
		guard !condition() else { return }
		let text = message()
		failures.append(text)
		print("FAILED: \(text)")
	}

	/// The foreground signal AF-01/AF-02 are triggered by. The shim makes
	/// `didBecomeActiveNotification` a plain `Notification.Name`, so posting it is the whole thing.
	static func postForegroundSignal() {
		NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
	}

	static func main() {
		// The rows print as they run. Without this the output sits in libc's block buffer until the
		// process ends, so a row that hangs looks exactly like a row that printed nothing — and the
		// check is normally read from a file, not a terminal.
		setbuf(stdout, nil)

		// ── AF-01 row 1 — an empty dev key switches the whole layer off ──────────────────────
		// Executes `AppsFlyerService.swift:51-57`. Green: `:51` returns before anything is
		// touched, having recorded the cause first.
		AppsFlyerLib.reset()
		ConfigurationIssues.shared.reset()
		let t1Service = AppsFlyerService(analytics: FakeAnalytics(), adapty: FakeAdapty())
		t1Service.configure(devKey: "", appId: "id-1", deviceId: "device-1", attTimeout: 12, isDebug: false)
		check(
			AppsFlyerLib.initializeCallCount == 0,
			"T1 AF-01 row 1: an empty dev key must initialize the SDK 0 times, got "
				+ "\(AppsFlyerLib.initializeCallCount)"
		)
		check(
			AppsFlyerLib.shared().delegate == nil
				&& AppsFlyerLib.shared().deepLinkDelegate == nil
				&& AppsFlyerLib.shared().customerUserID == nil,
			"T2 AF-01 row 1: an empty dev key must leave both delegates and customerUserID unset, "
				+ "got delegate=\(AppsFlyerLib.shared().delegate == nil ? "nil" : "set"), "
				+ "deepLinkDelegate=\(AppsFlyerLib.shared().deepLinkDelegate == nil ? "nil" : "set"), "
				+ "customerUserID=\(String(describing: AppsFlyerLib.shared().customerUserID))"
		)
		// The observer is proved absent by its effect: had `:77-82` run, this signal would set the
		// flag at `:121` and reach `start()` at `:122`.
		postForegroundSignal()
		check(
			t1Service.didStartAppsFlyer == false && AppsFlyerLib.startCallCount == 0,
			"T3 AF-01 row 1: with the layer off a foreground signal must reach the SDK 0 times and "
				+ "leave didStartAppsFlyer false, got \(AppsFlyerLib.startCallCount) start(s), "
				+ "didStartAppsFlyer=\(t1Service.didStartAppsFlyer)"
		)
		// The other half of AF-01 row 1 — "the disabled layer must leave a trace visible outside
		// Xcode". This check builds WITHOUT `-D DEBUG` on purpose, so `debugLog` writes nothing at
		// all here: what is asserted is the one channel that survives a release build, and the
		// assert names the cause rather than the fact a line exists. Green since the empty-key
		// branch records it (`:52-55`).
		check(
			ConfigurationIssues.shared.all.contains { $0.contains("dev key") },
			"T26 AF-01 row 1: an empty dev key must record a readable reason, got "
				+ "\(ConfigurationIssues.shared.all)"
		)

		// ── AF-01 row 2 — the ATT wait limit is the app's parameter, not a package constant ───
		// The documented limit is scenario-dependent — 60 s for a prompt at launch, 120 s for one
		// after a tutorial — so a constant in the package is a guess about an app it cannot see.
		// The assert names 12 s: a value no default would produce by accident.
		AppsFlyerLib.reset()
		let t4Service = AppsFlyerService(analytics: FakeAnalytics(), adapty: FakeAdapty())
		t4Service.configure(devKey: "key-1", appId: "id-1", deviceId: "device-1", attTimeout: 12, isDebug: false)
		NotificationCenter.default.removeObserver(t4Service)
		check(
			AppsFlyerLib.lastATTTimeout == 12,
			"T4 AF-01 row 2: the ATT wait limit must be the app's own 12 s, got "
				+ "\(String(describing: AppsFlyerLib.lastATTTimeout))"
		)

		// ── AF-01 row 3 — SDK debug logging follows the app's `isDebug` key ──────────────────
		// Both directions are asserted, and only the `true` one is evidence on its own: with a
		// hardwired `false` in the package a `false` expectation would pass without any key
		// existing. The `false` run is here for the other half of the requirement — the key is
		// obeyed, not merely accepted — and the docs are explicit that it must be off in a
		// shipping build.
		AppsFlyerLib.reset()
		let t5Service = AppsFlyerService(analytics: FakeAnalytics(), adapty: FakeAdapty())
		t5Service.configure(devKey: "key-1", appId: "id-1", deviceId: "device-1", attTimeout: 12, isDebug: true)
		NotificationCenter.default.removeObserver(t5Service)
		check(
			AppsFlyerLib.shared().isDebug == true,
			"T5 AF-01 row 3: configured with the app's debug key on, the SDK's isDebug must be "
				+ "true, got \(AppsFlyerLib.shared().isDebug)"
		)
		AppsFlyerLib.reset()
		let t5OffService = AppsFlyerService(analytics: FakeAnalytics(), adapty: FakeAdapty())
		t5OffService.configure(devKey: "key-1", appId: "id-1", deviceId: "device-1", attTimeout: 12, isDebug: false)
		NotificationCenter.default.removeObserver(t5OffService)
		check(
			AppsFlyerLib.shared().isDebug == false,
			"T5 AF-01 row 3: configured with the key off, the SDK's isDebug must be false, got "
				+ "\(AppsFlyerLib.shared().isDebug)"
		)

		// AF-01 row 4 (no `deinit`, so the foreground observer outlives the object) is NOT
		// covered: on the Foundation this check runs against, `addObserver(_:selector:name:object:)`
		// holds a zeroing weak reference, so releasing the service is safe whether a `deinit`
		// exists or not — an assert here would pass for a reason that has nothing to do with the
		// row. The row is an OS-version read, exactly as its schema says.

		// ── AF-01 row 5 — a second `configure` must not stand the SDK up twice ───────────────
		// Executes `AppsFlyerService.swift:47-83` twice. Green: the guard at `:60-61` returns before
		// `:63` can stand the SDK up again.
		AppsFlyerLib.reset()
		let t6Service = AppsFlyerService(analytics: FakeAnalytics(), adapty: FakeAdapty())
		t6Service.configure(devKey: "key-1", appId: "id-1", deviceId: "device-1", attTimeout: 12, isDebug: false)
		t6Service.configure(devKey: "key-1", appId: "id-1", deviceId: "device-1", attTimeout: 12, isDebug: false)
		check(
			AppsFlyerLib.initializeCallCount == 1,
			"T6 AF-01 row 5: two configure() calls must initialize the SDK once, got "
				+ "\(AppsFlyerLib.initializeCallCount)"
		)
		// The second half of the row: the duplicate registration must still not double a session.
		// Green because the second `configure` never reached `:77-82`, so there is only one
		// observer. It used to be green for a different reason — the AF-02 flag swallowed the
		// second start — and that reason is gone, which is exactly why this assert stays here.
		postForegroundSignal()
		NotificationCenter.default.removeObserver(t6Service)
		check(
			AppsFlyerLib.startCallCount == 1,
			"T7 AF-01 row 5: after a doubled configure one foreground signal must reach the SDK "
				+ "once, got \(AppsFlyerLib.startCallCount)"
		)

		// AF-02 row 1 (start belongs on every foreground return, not once per process) is covered
		// at the end of this file, by T25. It waited there on purpose: while its requirement was
		// evidence level 4 — a typical use of the SDK, unverified against the documentation — an
		// assert would have pinned a guess. The docs closed the question on 2026-09-09, and the
		// assert followed.

		// ── AF-02 row 2 — the start flag is internal on purpose, and readable ────────────────
		// Executes `AppsFlyerService.swift:120-124` and reads `:24`. The row is held twice over:
		// the line below only compiles because `:24` is `var`, not `private var`, and the value it
		// reads is the observable trace the flag was kept for after exactly one signal. Green.
		AppsFlyerLib.reset()
		let t8Service = AppsFlyerService(analytics: FakeAnalytics(), adapty: FakeAdapty())
		t8Service.configure(devKey: "key-1", appId: "id-1", deviceId: "device-1", attTimeout: 12, isDebug: false)
		postForegroundSignal()
		NotificationCenter.default.removeObserver(t8Service)
		check(
			t8Service.didStartAppsFlyer == true && AppsFlyerLib.startCallCount == 1,
			"T8 AF-02 row 2: one foreground signal must set didStartAppsFlyer true and reach the "
				+ "SDK once, got didStartAppsFlyer=\(t8Service.didStartAppsFlyer), "
				+ "\(AppsFlyerLib.startCallCount) start(s)"
		)

		// ── AF-02 row 3 — two foreground signals in one tick are safe ────────────────────────
		// Executes `startAppsFlyer` twice in the same run-loop turn, both times all the way to the
		// SDK. The flag is still cleared between them, and now that it gates nothing that line only
		// documents the row's own question: the service owns no state that a second pass could
		// corrupt, so both must complete. Serialising the requests is the SDK's job. Green.
		AppsFlyerLib.reset()
		let t9Service = AppsFlyerService(analytics: FakeAnalytics(), adapty: FakeAdapty())
		t9Service.configure(devKey: "key-1", appId: "id-1", deviceId: "device-1", attTimeout: 12, isDebug: false)
		postForegroundSignal()
		t9Service.didStartAppsFlyer = false
		postForegroundSignal()
		NotificationCenter.default.removeObserver(t9Service)
		check(
			AppsFlyerLib.startCallCount == 2,
			"T9 AF-02 row 3: two overlapping foreground signals must both reach the SDK, got "
				+ "\(AppsFlyerLib.startCallCount) start(s)"
		)

		// AF-02 row 4 (the observer registered twice) is NOT covered here on purpose — it is a
		// pointer to AF-01 row 5, and covering it twice would hide which assert actually carries
		// it. T6 and T7 above are that assert.

		// ── AF-03 row 1 — the event carries the cleaned dictionary, end to end ───────────────
		// Executes `AppsFlyerService.swift:131` and `:136`. The filter itself is already covered by
		// `appsflyer-attribution-check.sh`; what this adds is the through-the-service half its
		// schema asks for — that the dictionary reaching analytics is the cleaned one and not the
		// raw one. Green.
		AppsFlyerLib.reset()
		let t10Analytics = FakeAnalytics()
		let t10Service = AppsFlyerService(analytics: t10Analytics, adapty: FakeAdapty())
		let t10Raw: [AnyHashable: Any] = [
			"af_status": "Non-organic",
			"campaign": "spring",
			"nested": ["a": 1],
			"nulled": NSNull(),
			42: "int key",
		]
		t10Service.onConversionDataSuccess(t10Raw)
		let t10Event = t10Analytics.events.first
		check(
			t10Analytics.events.count == 1
				&& t10Event?.name == "af_onConversionData"
				&& t10Event?.properties?.count == 2
				&& t10Event?.properties?["af_status"] as? String == "Non-organic"
				&& t10Event?.properties?["campaign"] as? String == "spring",
			"T10 AF-03 row 1: af_onConversionData must carry exactly the 2 cleaned scalars "
				+ "(af_status=Non-organic, campaign=spring), got \(t10Analytics.events.count) "
				+ "event(s), name \(String(describing: t10Event?.name)), properties "
				+ "\(String(describing: t10Event?.properties))"
		)

		// ── AF-03 row 2 — an empty AppsFlyer UID is "no UID", not an identifier ──────────────
		// Executes `AppsFlyerService.swift:147-148`. Green: `:148` turns an empty answer into `nil`
		// before it travels, so it can no longer reach Adapty as a valid identifier.
		AppsFlyerLib.reset()
		AppsFlyerLib.appsFlyerUID = ""
		let t11Adapty = FakeAdapty()
		let t11Service = AppsFlyerService(analytics: FakeAnalytics(), adapty: t11Adapty)
		t11Service.onConversionDataSuccess(["af_status": "Organic"])
		check(
			t11Adapty.attributionNetworkUserIds.count == 1
				&& t11Adapty.attributionNetworkUserIds[0] == nil,
			"T11 AF-03 row 2: an empty AppsFlyer UID must reach Adapty as nil, got "
				+ "\(t11Adapty.attributionNetworkUserIds.count) write(s), networkUserId "
				+ "\(String(describing: t11Adapty.attributionNetworkUserIds.first ?? nil))"
		)

		// ── AF-03 row 3 — event and profile property must not contradict each other ──────────
		// Executes `AppsFlyerService.swift:136` and `:139-143`. Both addressees speak from the one
		// cleaned dictionary at `:131`; a numeric `af_status` used to split them — the event kept
		// 42 while the property read the raw dictionary and said "unknown". T12 pins the event
		// side, T13 the property side, and `describe` (`:170-173`) is what makes them agree.
		// The exact rendering "42" is the implementation's choice — what the row forbids is the
		// two answers disagreeing, and naming a value is the only way to assert that precisely.
		AppsFlyerLib.reset()
		let t12Analytics = FakeAnalytics()
		let t12Service = AppsFlyerService(analytics: t12Analytics, adapty: FakeAdapty())
		t12Service.onConversionDataSuccess(["af_status": 42, "media_source": "fb", "campaign": "spring"])
		check(
			t12Analytics.events.first?.properties?["af_status"] as? Int == 42,
			"T12 AF-03 row 3: the event must carry af_status 42 from the cleaned data, got "
				+ "\(String(describing: t12Analytics.events.first?.properties?["af_status"]))"
		)
		check(
			t12Analytics.userProperties.first?["af_status"] as? String == "42",
			"T13 AF-03 row 3: the profile property must describe af_status the same way the event "
				+ "does — \"42\" — got "
				+ "\(String(describing: t12Analytics.userProperties.first?["af_status"]))"
		)

		// AF-03 row 4 (a rejected attribution write must be retried) is covered elsewhere, on
		// purpose: the retry lives in `AdaptyService.updateAppsFlyerAttribution`, which this check
		// does not compile — `FakeAdapty` stands in its place, and it has no channel to signal a
		// rejection with either (`updateAppsFlyerAttribution` returns Void). The row is closed by
		// `AdaptyServiceCheck.swift` T28 (AD-06 row 1), which asserts the queued write is repeated
		// after activation with the same `networkUserId`.

		// AF-03 row 5 (profile property names colliding with the app's own) is a pointer to AN-03
		// row 4 — and that pointer used to run in a circle, because Amplitude's check pointed back
		// here. It is asserted once, at the end of this file (T24), where the writing code lives.

		// ── AF-04 row 1 — the `-` placeholder belongs in the event only ──────────────────────
		// Executes `AppsFlyerService.swift:201-211`. T14 pins the event half (the fixed payload
		// needs every field present). T15 held the spec for the two profile writes and is green
		// since `:208` returns before either of them. Both green.
		AppsFlyerLib.reset()
		let t14Analytics = FakeAnalytics()
		let t14Adapty = FakeAdapty()
		let t14Service = AppsFlyerService(analytics: t14Analytics, adapty: t14Adapty)
		t14Service.applyDeepLink(deeplinkValue: nil, clickEvent: [:])
		check(
			t14Analytics.events.first?.properties?["deep_link_value"] as? String == "-",
			"T14 AF-04 row 1: the event must carry the \"-\" placeholder, got "
				+ "\(String(describing: t14Analytics.events.first?.properties?["deep_link_value"]))"
		)
		check(
			t14Analytics.userProperties.count == 0 && t14Adapty.profileValues.count == 0,
			"T15 AF-04 row 1: an empty deep link value must reach 0 analytics profiles and 0 "
				+ "Adapty profiles, got \(t14Analytics.userProperties.count) and "
				+ "\(t14Adapty.profileValues.count)"
		)

		// ── AF-04 row 2 — "found" with no content is a contradiction, not a deep link ────────
		// Executes `AppsFlyerService.swift:181-188`. Green: `:181` returns before `:189`.
		AppsFlyerLib.reset()
		let t16Analytics = FakeAnalytics()
		let t16Adapty = FakeAdapty()
		let t16Service = AppsFlyerService(analytics: t16Analytics, adapty: t16Adapty)
		t16Service.didResolveDeepLink(DeepLinkResult(status: .found, deepLink: nil))
		check(
			t16Analytics.events.count == 0
				&& t16Analytics.userProperties.count == 0
				&& t16Adapty.profileValues.count == 0,
			"T16 AF-04 row 2: status .found with no deepLink must log 0 events, 0 analytics "
				+ "profiles and 0 Adapty profiles, got \(t16Analytics.events.count), "
				+ "\(t16Analytics.userProperties.count), \(t16Adapty.profileValues.count)"
		)
		// The other half of the row — the contradiction must leave a trace visible outside Xcode.
		// Not `configurationIssues`: nothing here is misconfigured, the SDK simply contradicted
		// itself once, and a list meant for "no retry will fix this" would fill up with weather.
		// A counter on the service is what the schema asks for, and it is the app's to read —
		// `:185` counts it, and `IntegrationKit.droppedDeepLinks` hands it out. Green.
		check(
			t16Service.droppedDeepLinks == 1,
			"T27 AF-04 row 2: a \"found\" with no content must be counted as a dropped deep link, "
				+ "got \(t16Service.droppedDeepLinks)"
		)

		// ── AF-04 row 3 — the deep-link event has a fixed eleven-field shape ─────────────────
		// Executes `AppsFlyerService.swift:202-203` with two of the eleven fields present. The
		// mapping itself is covered by `appsflyer-attribution-check.sh`; this is the same claim
		// seen from the analytics end, where the count actually matters. Green.
		AppsFlyerLib.reset()
		let t17Analytics = FakeAnalytics()
		let t17Service = AppsFlyerService(analytics: t17Analytics, adapty: FakeAdapty())
		t17Service.applyDeepLink(deeplinkValue: "promo", clickEvent: ["campaign": "brand", "media_source": "fb"])
		let t17Event = t17Analytics.events.first
		check(
			t17Event?.name == "af_didResolveDeepLink"
				&& t17Event?.properties?.count == 11
				&& t17Event?.properties?["campaign"] as? String == "brand"
				&& t17Event?.properties?["af_sub5"] as? String == "",
			"T17 AF-04 row 3: af_didResolveDeepLink must carry exactly 11 fields with campaign="
				+ "brand and the 9 absent ones empty, got name "
				+ "\(String(describing: t17Event?.name)), \(String(describing: t17Event?.properties?.count)) "
				+ "field(s), campaign \(String(describing: t17Event?.properties?["campaign"])), "
				+ "af_sub5 \(String(describing: t17Event?.properties?["af_sub5"]))"
		)

		// ── AF-04 row 4 — the quiet delegate branches are contract, and must stay quiet ──────
		// Executes `AppsFlyerService.swift:190-191` (T18) and `:192-193` (T19). The row's third
		// branch — `.found` with no content, `:181-188` — is covered once, by T16 above.
		AppsFlyerLib.reset()
		let t18Analytics = FakeAnalytics()
		let t18Adapty = FakeAdapty()
		let t18Service = AppsFlyerService(analytics: t18Analytics, adapty: t18Adapty)
		t18Service.didResolveDeepLink(DeepLinkResult(status: .notFound))
		check(
			t18Analytics.events.count == 0
				&& t18Analytics.userProperties.count == 0
				&& t18Adapty.profileValues.count == 0,
			"T18 AF-04 row 4: status .notFound must log 0 events, 0 analytics profiles and 0 "
				+ "Adapty profiles, got \(t18Analytics.events.count), "
				+ "\(t18Analytics.userProperties.count), \(t18Adapty.profileValues.count)"
		)
		let t19Analytics = FakeAnalytics()
		let t19Adapty = FakeAdapty()
		let t19Service = AppsFlyerService(analytics: t19Analytics, adapty: t19Adapty)
		t19Service.didResolveDeepLink(
			DeepLinkResult(status: .failure, error: NSError(domain: "AppsFlyer", code: -1009))
		)
		check(
			t19Analytics.events.count == 0
				&& t19Analytics.userProperties.count == 0
				&& t19Adapty.profileValues.count == 0,
			"T19 AF-04 row 4: status .failure must log 0 events, 0 analytics profiles and 0 "
				+ "Adapty profiles, got \(t19Analytics.events.count), "
				+ "\(t19Analytics.userProperties.count), \(t19Adapty.profileValues.count)"
		)

		// ── AF-04 row 5 — the second deep link wins, on purpose ──────────────────────────────
		// Executes `AppsFlyerService.swift:209-210` twice. This row pins a decision, not a defect:
		// the user really did arrive from the newer campaign. Green.
		AppsFlyerLib.reset()
		let t20Analytics = FakeAnalytics()
		let t20Adapty = FakeAdapty()
		let t20Service = AppsFlyerService(analytics: t20Analytics, adapty: t20Adapty)
		t20Service.applyDeepLink(deeplinkValue: "first", clickEvent: [:])
		t20Service.applyDeepLink(deeplinkValue: "second", clickEvent: [:])
		check(
			t20Analytics.userProperties.count == 2
				&& t20Analytics.userProperties.last?["deep_link_value"] as? String == "second"
				&& t20Adapty.profileValues.count == 2
				&& t20Adapty.profileValues.last?.value == "second"
				&& t20Adapty.profileValues.last?.key == "deep_link_value",
			"T20 AF-04 row 5: after two deep links both profiles must hold \"second\", got "
				+ "\(String(describing: t20Analytics.userProperties.last?["deep_link_value"])) after "
				+ "\(t20Analytics.userProperties.count) analytics write(s) and "
				+ "\(String(describing: t20Adapty.profileValues.last?.value)) after "
				+ "\(t20Adapty.profileValues.count) Adapty write(s)"
		)

		// ── AF-05 row 1 — the system gets its answer even when the SDK never calls back ──────
		// Executes `AppsFlyerService.swift:85-113` with the SDK swallowing the block. Green: the
		// answer no longer lives inside the SDK's block alone — `:90-95` lets exactly one through
		// and `:112` fires it unconditionally, so the app never sits on its launch screen.
		AppsFlyerLib.reset()
		AppsFlyerLib.continueBehaviour = .neverCallsBlock
		let t21Service = AppsFlyerService(analytics: FakeAnalytics(), adapty: FakeAdapty())
		// Configured on purpose: the row is about the forwarding path. An unconfigured service
		// answers from the AF-05 row 3 gate instead and would make this assert green without the
		// SDK ever being asked — T28 is the one that owns that branch.
		t21Service.configure(devKey: "key-1", appId: "id-1", deviceId: "device-1", attTimeout: 12, isDebug: false)
		NotificationCenter.default.removeObserver(t21Service)
		var t21HandlerCalls = 0
		var t21Received: [UIUserActivityRestoring]?
		t21Service.handleContinue(NSUserActivity(activityType: "check.continue")) { restoring in
			t21HandlerCalls += 1
			t21Received = restoring
		}
		check(
			t21HandlerCalls == 1 && (t21Received?.count ?? 0) == 0,
			"T21 AF-05 row 1: a swallowed SDK block must still answer the system exactly once, "
				+ "with 0 objects, got \(t21HandlerCalls) call(s) carrying "
				+ "\(t21Received?.count ?? 0) object(s)"
		)

		// ── AF-05 row 2 — one foreign object must not take the whole array with it ───────────
		// Executes `AppsFlyerService.swift:108` with a mixed array. Green: the cast runs per
		// element, so a single `String` among the objects no longer turns the entire answer into
		// nil and takes the good object with it.
		AppsFlyerLib.reset()
		let t22Restorer = FakeRestorer()
		AppsFlyerLib.continueBehaviour = .callsWith([t22Restorer, "not a restoring object"])
		let t22Service = AppsFlyerService(analytics: FakeAnalytics(), adapty: FakeAdapty())
		// Same reason as T21: without a configured layer the answer never comes from the SDK.
		t22Service.configure(devKey: "key-1", appId: "id-1", deviceId: "device-1", attTimeout: 12, isDebug: false)
		NotificationCenter.default.removeObserver(t22Service)
		var t22Received: [UIUserActivityRestoring]?
		t22Service.handleContinue(NSUserActivity(activityType: "check.continue")) { restoring in
			t22Received = restoring
		}
		check(
			t22Received?.count == 1 && t22Received?.first === t22Restorer,
			"T22 AF-05 row 2: a mixed answer must reach the system as exactly 1 object — the "
				+ "conforming one — got \(String(describing: t22Received?.count)) object(s)"
		)

		// ── AF-05 row 3 — the forwards stay silent while the layer is off ────────────────────
		// The gate the schema names lives in `IntegrationKit.swift`, which this check does not
		// compile — it would drag in Adapty, Amplitude, StoreKit and Premium. Calling the forwards
		// straight on the service takes the branch that has no gate at all, and that branch is the
		// row: a service that never came up must not reach into an SDK that was never initialized.
		// The handler still has to be answered — an unconfigured layer that simply returns would
		// hang the app on its launch screen, which is AF-05 row 1 all over again. Both green:
		// `AppsFlyerService.swift:97-103` gates the forward and answers in the same breath.
		// The row's trace half is carried once, by T26 above: the reason is recorded when the empty
		// key arrives, and `ConfigurationIssues` keeps one line per cause, not one per call.
		AppsFlyerLib.reset()
		let t28Service = AppsFlyerService(analytics: FakeAnalytics(), adapty: FakeAdapty())
		t28Service.configure(devKey: "", appId: "id-1", deviceId: "device-1", attTimeout: 12, isDebug: false)
		var t28HandlerCalls = 0
		var t28Received: [UIUserActivityRestoring]?
		t28Service.handleContinue(NSUserActivity(activityType: "check.continue")) { restoring in
			t28HandlerCalls += 1
			t28Received = restoring
		}
		t28Service.handleOpen(URL(string: "https://example.com/promo")!, options: [:])
		NotificationCenter.default.removeObserver(t28Service)
		check(
			AppsFlyerLib.continueCallCount == 0 && AppsFlyerLib.handleOpenCallCount == 0,
			"T28 AF-05 row 3: with the layer off both forwards must reach the SDK 0 times, got "
				+ "\(AppsFlyerLib.continueCallCount) continue(s) and "
				+ "\(AppsFlyerLib.handleOpenCallCount) open(s)"
		)
		check(
			t28HandlerCalls == 1 && (t28Received?.count ?? 0) == 0,
			"T28 AF-05 row 3: the system must still get exactly one empty answer, got "
				+ "\(t28HandlerCalls) call(s) carrying \(t28Received?.count ?? 0) object(s)"
		)

		// ── AF-06 row 1 — a failed attribution says which failure it was ─────────────────────
		// Executes `AppsFlyerService.swift:151-166`. `localizedDescription` is what the code used to
		// keep, and it is exactly what cannot tell a dropped connection from a wrong key — the one
		// thing the row exists to distinguish. Both the domain and the code are named, and the
		// channel asserted is the one that survives a release build. Green.
		AppsFlyerLib.reset()
		ConfigurationIssues.shared.reset()
		let t29Service = AppsFlyerService(analytics: FakeAnalytics(), adapty: FakeAdapty())
		t29Service.onConversionDataFail(NSError(domain: "AppsFlyerErrorDomain", code: -1009))
		check(
			ConfigurationIssues.shared.all.contains { $0.contains("AppsFlyerErrorDomain") && $0.contains("-1009") },
			"T29 AF-06 row 1: a failed attribution must record both the error domain and its code, "
				+ "got \(ConfigurationIssues.shared.all)"
		)

		// AF-06 row 2 (the legacy open-attribution callback discards its data) is covered by T23
		// below as far as it can be: its assert — 0 events, 0 profiles, 0 Adapty writes — is
		// exactly T23's, so it is made once. Its remaining half, a trace carrying what arrived, is
		// NOT covered for the same reason as AF-06 row 1.

		// ── AF-06 row 3 — the failure callback stays silent ──────────────────────────────────
		// Executes the `onConversionDataFail` branch. The row started as three callbacks; the two
		// legacy ones are gone with AF-06 row 2 (they are absent from `AppsFlyerLibDelegate` in
		// 7.0.2, so the SDK could never have called them), and the row does not weaken for it —
		// this is the one branch the SDK can still reach. Recording the cause is not a side effect
		// in the sense this row forbids: what must stay at zero is anything that looks like data.
		AppsFlyerLib.reset()
		let t23Analytics = FakeAnalytics()
		let t23Adapty = FakeAdapty()
		let t23Service = AppsFlyerService(analytics: t23Analytics, adapty: t23Adapty)
		t23Service.onConversionDataFail(NSError(domain: "AppsFlyer", code: -1009))
		check(
			t23Analytics.events.count == 0
				&& t23Analytics.userProperties.count == 0
				&& t23Adapty.attributionData.count == 0
				&& t23Adapty.profileValues.count == 0,
			"T23 AF-06 row 3: the failure callback must log 0 events, 0 analytics profiles, 0 Adapty "
				+ "attributions and 0 Adapty profiles, got "
				+ "\(t23Analytics.events.count), \(t23Analytics.userProperties.count), "
				+ "\(t23Adapty.attributionData.count), \(t23Adapty.profileValues.count)"
		)

		// ── AN-03 row 4 / AF-03 row 5 — the package's profile properties must be its own ────
		// Executes `AppsFlyerService.swift:139-143`. Neither schema's check was covering this row:
		// AF-03 row 5 points at AN-03 row 4 and AN-03 row 4 points back here, so the pointer went
		// in a circle and nobody asserted it. The code that writes the names lives in this file's
		// subject, so the assert belongs here. Green: all three names carry the `af_` prefix, so
		// the app's own `status` or `campaign_name` and the package's no longer overwrite each
		// other with nothing to tell them apart. The prefix itself is the implementation's choice
		// — the two events already carry it — and naming it is the only way to assert
		// "recognizable" precisely.
		AppsFlyerLib.reset()
		let propertyNameAnalytics = FakeAnalytics()
		let propertyNameService = AppsFlyerService(analytics: propertyNameAnalytics, adapty: FakeAdapty())
		propertyNameService.onConversionDataSuccess([
			"af_status": "Non-organic",
			"media_source": "fb",
			"campaign": "spring",
		])
		let writtenPropertyNames = Set((propertyNameAnalytics.userProperties.first ?? [:]).keys)
		check(
			writtenPropertyNames == ["af_status", "af_media_source", "af_campaign_name"],
			"T24 AN-03 row 4: the profile properties the package writes must carry the same af_ "
				+ "prefix its events do, got \(writtenPropertyNames.sorted())"
		)

		// ── AF-02 row 1 — start belongs on every foreground return ───────────────────────────
		// The open question behind this row was closed against the docs on 2026-09-09: `start` is
		// documented for `applicationDidBecomeActive`, and near-identical starts are deduped by
		// the SDK itself (`minTimeBetweenSessions`, 5 s), not by a flag on our side. That made the
		// once-per-process guard a defect rather than a boundary, and it is gone:
		// `AppsFlyerService.swift:120-124` starts unconditionally. Two foreground signals with
		// nothing reset in between — unlike T9, which clears the flag on purpose — so the second
		// one still reaches the SDK. Green.
		AppsFlyerLib.reset()
		let t25Service = AppsFlyerService(analytics: FakeAnalytics(), adapty: FakeAdapty())
		t25Service.configure(devKey: "key-1", appId: "id-1", deviceId: "device-1", attTimeout: 12, isDebug: false)
		postForegroundSignal()
		postForegroundSignal()
		NotificationCenter.default.removeObserver(t25Service)
		check(
			AppsFlyerLib.startCallCount == 2,
			"T25 AF-02 row 1: a second foreground return must start a new session, got "
				+ "\(AppsFlyerLib.startCallCount) start(s)"
		)

		// ── AF-01 row 6 — what a successful `configure` actually hands the SDK ───────────────
		// Every AF-01 assert until now read the empty-key branch: T1–T3 and T26 name what must NOT
		// happen. The schema's other four steps — initialize with the app's key and id, the CUID,
		// both delegates — had no assert at all, so any of them could be dropped and every existing
		// row would stay green. T32 is the ordering half the schema's own note called out as
		// uncatchable: the docs say a CUID set after `start` is not associated with the install
		// event, so what matters is not that the property holds the id afterwards but that it
		// already held it when the session started.
		AppsFlyerLib.reset()
		let handedOverAnalytics = FakeAnalytics()
		let handedOverService = AppsFlyerService(analytics: handedOverAnalytics, adapty: FakeAdapty())
		handedOverService.configure(devKey: "key-1", appId: "id-1", deviceId: "device-1", attTimeout: 12, isDebug: false)
		check(
			AppsFlyerLib.lastDevKey == "key-1"
				&& AppsFlyerLib.lastAppId == "id-1"
				&& AppsFlyerLib.shared().customerUserID == "device-1"
				&& AppsFlyerLib.shared().delegate === handedOverService
				&& AppsFlyerLib.shared().deepLinkDelegate === handedOverService,
			"T30 AF-01 row 6: configure must hand the SDK the app's key-1/id-1, the deviceId as "
				+ "customerUserID and this service as both delegates, got devKey "
				+ "\(String(describing: AppsFlyerLib.lastDevKey)), appId "
				+ "\(String(describing: AppsFlyerLib.lastAppId)), customerUserID "
				+ "\(String(describing: AppsFlyerLib.shared().customerUserID)), delegate "
				+ "\(AppsFlyerLib.shared().delegate === handedOverService ? "this" : "other/nil"), "
				+ "deepLinkDelegate "
				+ "\(AppsFlyerLib.shared().deepLinkDelegate === handedOverService ? "this" : "other/nil")"
		)
		check(
			AppsFlyerLib.startCallCount == 0,
			"T31 AF-01 row 6: configure alone must start 0 sessions — the session belongs to the "
				+ "foreground signal (AF-02) — got \(AppsFlyerLib.startCallCount)"
		)
		postForegroundSignal()
		NotificationCenter.default.removeObserver(handedOverService)
		check(
			AppsFlyerLib.customerUserIDAtStart == "device-1",
			"T32 AF-01 row 6: customerUserID must already be device-1 when start() runs, or the "
				+ "install event is attributed to nobody, got "
				+ "\(String(describing: AppsFlyerLib.customerUserIDAtStart))"
		)

		// ── AF-03 row 6 — an absent attribution field is an answer, and must read as one ─────
		// Executes `AppsFlyerService.swift:139-143` and `:170-173` with two of the three fields
		// missing. The schema requires the default "unknown" rather than an empty or absent
		// property: a dashboard cannot segment on a property that is not there, and "" and "the
		// SDK did not say" look identical once they are in Amplitude. T24 pins the three names,
		// never their values, so nothing until now would have noticed the default disappearing.
		AppsFlyerLib.reset()
		let sparseAnalytics = FakeAnalytics()
		let sparseService = AppsFlyerService(analytics: sparseAnalytics, adapty: FakeAdapty())
		sparseService.onConversionDataSuccess(["campaign": "spring"])
		let sparseProperties = sparseAnalytics.userProperties.first ?? [:]
		check(
			sparseProperties["af_status"] as? String == "unknown"
				&& sparseProperties["af_media_source"] as? String == "unknown"
				&& sparseProperties["af_campaign_name"] as? String == "spring",
			"T33 AF-03 row 6: fields the SDK did not send must reach the profile as \"unknown\", "
				+ "not empty or absent, got af_status "
				+ "\(String(describing: sparseProperties["af_status"])), af_media_source "
				+ "\(String(describing: sparseProperties["af_media_source"])), af_campaign_name "
				+ "\(String(describing: sparseProperties["af_campaign_name"]))"
		)

		// ── AF-05 row 4 — the URL forward reaches the SDK unchanged ──────────────────────────
		// Executes `AppsFlyerService.swift:115-118` on a configured layer. T28 owns the negative
		// half — 0 forwards while the layer is off — and nothing owned the positive one: the
		// schema's "forward it as it is" is a claim about the URL, and a service that forwarded
		// some other URL, or swallowed it, would have left every AF-05 assert green.
		AppsFlyerLib.reset()
		let forwardedURL = URL(string: "https://example.com/promo?af_sub1=vip")!
		let forwardService = AppsFlyerService(analytics: FakeAnalytics(), adapty: FakeAdapty())
		forwardService.configure(devKey: "key-1", appId: "id-1", deviceId: "device-1", attTimeout: 12, isDebug: false)
		NotificationCenter.default.removeObserver(forwardService)
		forwardService.handleOpen(forwardedURL, options: [:])
		check(
			AppsFlyerLib.handleOpenCallCount == 1 && AppsFlyerLib.lastOpenedURL == forwardedURL,
			"T34 AF-05 row 4: a configured layer must forward the URL to the SDK once, unchanged, "
				+ "got \(AppsFlyerLib.handleOpenCallCount) call(s) carrying "
				+ "\(String(describing: AppsFlyerLib.lastOpenedURL))"
		)

		// ── AF-01 row 1, second switch — a test run must not stand the SDK up ────────────────
		// The row asks for two switches, not one: an empty dev key is an app that ships without
		// attribution, and `isTestsRunning` is a run that must not be measured. Until this key
		// existed only the first one worked, so a UI-test run of the app with its real dev key sent
		// sessions and install data into the live AppsFlyer account — attribution that advertising
		// budget is steered by, moved by a robot. The app computes the answer itself (`-uitest`
		// among the arguments, or `XCTestConfigurationFilePath` in the environment).
		//
		// The foreground signal is posted deliberately: `configure` never starts a session itself
		// (T31), so the only way to prove the observer was not registered is to fire the thing it
		// listens to and watch nothing happen. The reason is asserted apart from the dev-key one —
		// a shared line would send whoever reads it looking for a key that is perfectly fine.
		AppsFlyerLib.reset()
		ConfigurationIssues.shared.reset()
		let testRunService = AppsFlyerService(analytics: FakeAnalytics(), adapty: FakeAdapty())
		testRunService.configure(devKey: "key-1", appId: "id-1", deviceId: "device-1", attTimeout: 12, isDebug: false, isTestsRunning: true)
		postForegroundSignal()
		NotificationCenter.default.removeObserver(testRunService)
		check(
			AppsFlyerLib.initializeCallCount == 0 && AppsFlyerLib.startCallCount == 0,
			"T35 AF-01 row 1: a test run must not initialize the SDK and must not register the "
				+ "foreground observer, got \(AppsFlyerLib.initializeCallCount) initialize(s) and "
				+ "\(AppsFlyerLib.startCallCount) start(s)"
		)
		check(
			ConfigurationIssues.shared.all.contains { $0.contains("test run") },
			"T35 AF-01 row 1: a test run must record its own reason, apart from the empty-dev-key "
				+ "one, got \(ConfigurationIssues.shared.all)"
		)

		// ── AF-01 row 3 — SDK debug logging rides the app's `isDebug`, not a switch of its own ──
		// T18/T19 already pin that the value travels from a parameter rather than a constant. What
		// changed is which parameter: the facade's separate `sdkDebugLogs` is gone, and this is the
		// same `isDebug` that decides crash collection — the row's whole point is that the app has
		// two keys and the package has none of its own. A test run leaves logging alone: the two
		// keys are different axes, and gluing them together would either drag another SDK's console
		// logs into every test run or silence attribution in every debug build.
		AppsFlyerLib.reset()
		let debugKeyService = AppsFlyerService(analytics: FakeAnalytics(), adapty: FakeAdapty())
		debugKeyService.configure(devKey: "key-1", appId: "id-1", deviceId: "device-1", attTimeout: 12, isDebug: true, isTestsRunning: false)
		NotificationCenter.default.removeObserver(debugKeyService)
		check(
			AppsFlyerLib.shared().isDebug && AppsFlyerLib.initializeCallCount == 1,
			"T36 AF-01 row 3: the app's isDebug must reach AppsFlyerLib.isDebug on a run that is not "
				+ "a test run, got isDebug=\(AppsFlyerLib.shared().isDebug), "
				+ "\(AppsFlyerLib.initializeCallCount) initialize(s)"
		)

		if failures.isEmpty {
			print("AppsFlyerService (AF-01…AF-06): 39/39 OK")
		} else {
			print("\(failures.count) of 39 asserts FAILED:")
			for failure in failures {
				print("  - \(failure)")
			}
			exit(1)
		}
	}
}
