//
//  AppsFlyerServiceCheck.swift
//  IntegrationKit
//
//  Written from the approved schemas AF-01…AF-06, not from the code. Twenty-four asserts carry
//  seventeen of the twenty-five rows plus AN-03 row 4, whose code lives here rather than in
//  Amplitude's; the eight rows that carry none say why in a comment above the block they belong
//  to, rather than being closed by a lookalike assert.
//
//  Red on purpose — the spec for behaviour the wrapper does not have yet:
//    T4  AF-01 row 2 — the ATT wait limit must be the app's, not the constant 60 at `:38`.
//    T5  AF-01 row 3 — SDK debug logging must follow the app's key, not the `false` at `:39`.
//    T6  AF-01 row 5 — a second `configure` must not initialize the SDK a second time.
//    T11 AF-03 row 2 — an empty AppsFlyer UID must reach Adapty as nil, not as "".
//    T13 AF-03 row 3 — the profile property and the event must not contradict each other.
//    T15 AF-04 row 1 — the `-` placeholder belongs in the event only, never in a profile.
//    T21 AF-05 row 1 — the restoration handler must answer even when the SDK never calls back.
//    T22 AF-05 row 2 — one foreign object must not take the whole restoration array with it.
//    T24 AN-03 row 4 — the profile properties the package writes must be recognizably its own.
//  The other fifteen are green and pin behaviour that is already correct — the silence of the
//  failure callbacks (T23), the fixed eleven-field deep-link payload (T17), last-attribution-wins
//  (T20) — so a later change cannot loosen any of it silently.
//
//  Built WITHOUT `-D DEBUG` on purpose: every row that asks for "a trace visible outside Xcode"
//  (AF-01 row 1, AF-04 row 2, AF-05 row 3, AF-06 rows 1-2) is measured against exactly the build
//  the user gets. None of those trace halves is asserted — see the comments; `debugLog` writes to
//  stdout, which this check has no way to read, and covering them needs an observable warning
//  channel in the package first.
//
//  This check does not stop at the first failing row: every row runs, every failure is collected,
//  and the summary at the end reports all of them with a non-zero exit code — same shape as
//  `CrashlyticsCheck`. A non-zero exit here is the expected, healthy outcome.
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

	func configure(apiKey: String, deviceId: String, firstOpenEvent: String?) {}

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

	func configure(apiKey: String, customerUserId: String, sessionsCounter: Int, placements: [String], analytics: AnalyticsTracking) {}

	func setProfileValue(value: String, key: String) {
		profileValues.append((value, key))
	}

	func hasPaywall(placement: String) -> Bool { false }
	func hasProductsForPaywall(placement: String, id: String) -> Bool { false }
	func hasProductsForPaywall(placement: String) -> Bool { false }
	func refreshPaywalls() {}
	func getRemoteValue<Type>(placement: String, key: String) -> Type? { nil }
	func logPaywallOpen(placement: String) {}
	func logOnboardingOpen(step: Int) {}
	func buyProduct(placement: String, id: String, completion: ((AdaptyPurchaseResult) -> Void)?) {}
	func integrateFirebase(appInstanceId: String) {}
	func integrateFacebook(id: String) {}
	func updateAppTrackingTransparencyStatus(_ status: ATTrackingManager.AuthorizationStatus) {}

	func updateAppsFlyerAttribution(_ data: [AnyHashable: Any], networkUserId: String?) {
		attributionData.append(data)
		attributionNetworkUserIds.append(networkUserId)
	}
}

/// AF-05 row 2 needs at least one object that survives the cast at `AppsFlyerService.swift:54`.
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
		// ── AF-01 row 1 — an empty dev key switches the whole layer off ──────────────────────
		// Executes `AppsFlyerService.swift:29-32`. Green: `:29` returns before anything is
		// touched.
		AppsFlyerLib.reset()
		let t1Service = AppsFlyerService(analytics: FakeAnalytics(), adapty: FakeAdapty())
		t1Service.configure(devKey: "", appId: "id-1", deviceId: "device-1")
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
		// The observer is proved absent by its effect: had `:41-46` run, this signal would set the
		// flag at `:67` and reach `start()` at `:68`.
		postForegroundSignal()
		check(
			t1Service.didStartAppsFlyer == false && AppsFlyerLib.startCallCount == 0,
			"T3 AF-01 row 1: with the layer off a foreground signal must reach the SDK 0 times and "
				+ "leave didStartAppsFlyer false, got \(AppsFlyerLib.startCallCount) start(s), "
				+ "didStartAppsFlyer=\(t1Service.didStartAppsFlyer)"
		)
		// The other half of AF-01 row 1 — "the disabled layer must leave a trace visible outside
		// Xcode" — is NOT covered: the only trace `:30` leaves goes through `debugLog`, which
		// compiles to nothing in this build and to stdout in a DEBUG one. Neither is readable from
		// inside the process, so covering it needs an observable warning channel in the package
		// first. Same reason as `CrashlyticsCheck`'s CR-01 row 1.

		// ── AF-01 row 2 — the ATT wait limit is the app's parameter, not a package constant ───
		// Executes `AppsFlyerService.swift:38`. RED: `:38` hardwires `timeoutInterval: 60`, and
		// `configure` has no parameter that could carry the app's own limit, so the 12 seconds
		// this row asks the app to choose cannot reach the SDK at all.
		AppsFlyerLib.reset()
		let t4Service = AppsFlyerService(analytics: FakeAnalytics(), adapty: FakeAdapty())
		t4Service.configure(devKey: "key-1", appId: "id-1", deviceId: "device-1")
		NotificationCenter.default.removeObserver(t4Service)
		check(
			AppsFlyerLib.lastATTTimeout == 12,
			"T4 AF-01 row 2: the ATT wait limit must be the app's own 12 s, got "
				+ "\(String(describing: AppsFlyerLib.lastATTTimeout))"
		)

		// ── AF-01 row 3 — SDK debug logging follows the app's `isDebug` key ──────────────────
		// Executes `AppsFlyerService.swift:39`. RED: `:39` writes `false` unconditionally and
		// `configure` has no `isDebug` parameter yet (decision 2026-09-08, task
		// 1218288104081038). Only the `true` direction is asserted — with the constant `false` in
		// place a `false` expectation passes without the key existing, so it would prove nothing.
		AppsFlyerLib.reset()
		let t5Service = AppsFlyerService(analytics: FakeAnalytics(), adapty: FakeAdapty())
		t5Service.configure(devKey: "key-1", appId: "id-1", deviceId: "device-1")
		NotificationCenter.default.removeObserver(t5Service)
		check(
			AppsFlyerLib.shared().isDebug == true,
			"T5 AF-01 row 3: configured with the app's debug key on, the SDK's isDebug must be "
				+ "true, got \(AppsFlyerLib.shared().isDebug)"
		)

		// AF-01 row 4 (no `deinit`, so the foreground observer outlives the object) is NOT
		// covered: on the Foundation this check runs against, `addObserver(_:selector:name:object:)`
		// holds a zeroing weak reference, so releasing the service is safe whether a `deinit`
		// exists or not — an assert here would pass for a reason that has nothing to do with the
		// row. The row is an OS-version read, exactly as its schema says.

		// ── AF-01 row 5 — a second `configure` must not stand the SDK up twice ───────────────
		// Executes `AppsFlyerService.swift:28-47` twice. RED: there is no guard, so `:34` runs
		// again.
		AppsFlyerLib.reset()
		let t6Service = AppsFlyerService(analytics: FakeAnalytics(), adapty: FakeAdapty())
		t6Service.configure(devKey: "key-1", appId: "id-1", deviceId: "device-1")
		t6Service.configure(devKey: "key-1", appId: "id-1", deviceId: "device-1")
		check(
			AppsFlyerLib.initializeCallCount == 1,
			"T6 AF-01 row 5: two configure() calls must initialize the SDK once, got "
				+ "\(AppsFlyerLib.initializeCallCount)"
		)
		// The second half of the row: the duplicate registration must still not double a session.
		// Green, and green because of the AF-02 flag at `:63-67`, not because of any guard here —
		// the observer really did run twice.
		postForegroundSignal()
		NotificationCenter.default.removeObserver(t6Service)
		check(
			AppsFlyerLib.startCallCount == 1,
			"T7 AF-01 row 5: after a doubled configure one foreground signal must reach the SDK "
				+ "once, got \(AppsFlyerLib.startCallCount)"
		)

		// AF-02 row 1 (start belongs on every foreground return, not once per process) is NOT
		// covered, deliberately. Its own risk table marks the requirement evidence level 4 — a
		// typical use of the SDK, unverified against AppsFlyer's documentation — and says the
		// claim must be confirmed there before a test freezes it. Writing the assert now would
		// pin a guess, so the row waits on that open question, not on this check.

		// ── AF-02 row 2 — the start flag is internal on purpose, and readable ────────────────
		// Executes `AppsFlyerService.swift:63-67` and reads `:20`. The row is held twice over:
		// the line below only compiles because `:20` is `var`, not `private var`, and the value
		// it reads is the guard's own state after exactly one signal. Green.
		AppsFlyerLib.reset()
		let t8Service = AppsFlyerService(analytics: FakeAnalytics(), adapty: FakeAdapty())
		t8Service.configure(devKey: "key-1", appId: "id-1", deviceId: "device-1")
		postForegroundSignal()
		NotificationCenter.default.removeObserver(t8Service)
		check(
			t8Service.didStartAppsFlyer == true && AppsFlyerLib.startCallCount == 1,
			"T8 AF-02 row 2: one foreground signal must set didStartAppsFlyer true and reach the "
				+ "SDK once, got didStartAppsFlyer=\(t8Service.didStartAppsFlyer), "
				+ "\(AppsFlyerLib.startCallCount) start(s)"
		)

		// ── AF-02 row 3 — two foreground signals in one tick are safe ────────────────────────
		// Executes `AppsFlyerService.swift:62-70` twice in the same run-loop turn, both times all
		// the way to `:68` — the guard is cleared between them, which is the exact use `:18-19`
		// says the internal flag exists for. The service owns no state besides that flag, so both
		// passes must complete and both must reach the SDK. Green.
		AppsFlyerLib.reset()
		let t9Service = AppsFlyerService(analytics: FakeAnalytics(), adapty: FakeAdapty())
		t9Service.configure(devKey: "key-1", appId: "id-1", deviceId: "device-1")
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
		// Executes `AppsFlyerService.swift:77` and `:83`. The filter itself is already covered by
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
		// Executes `AppsFlyerService.swift:90-91`. RED: `:90` hands whatever the SDK answers
		// straight to `:91`, so an empty string travels to Adapty as a valid identifier.
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
		// Executes `AppsFlyerService.swift:79` and `:83`. Both addressees must speak from the one
		// cleaned dictionary; with a numeric `af_status` they do not — the event keeps 42 (`:83`
		// via `:77`) while the property says "unknown" (`:79` reads the raw dictionary). T12 pins
		// the event side and is green; T13 states the spec for the property side and is RED.
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
			t12Analytics.userProperties.first?["status"] as? String == "42",
			"T13 AF-03 row 3: the profile property must describe af_status the same way the event "
				+ "does — \"42\" — got "
				+ "\(String(describing: t12Analytics.userProperties.first?["status"]))"
		)

		// AF-03 row 4 (a rejected attribution write must be retried) is NOT covered: the row's
		// coordinates are `AdaptyService.swift:172-180`, and this check does not compile
		// `AdaptyService` — `FakeAdapty` stands in its place. The retry the row asks for lives in
		// those lines, so no implementation of `AppsFlyerService` could turn an assert here green,
		// and the fake has no channel to signal the rejection with either
		// (`updateAppsFlyerAttribution` returns Void). The row waits on an AdaptyService
		// logicflow, which does not exist yet.

		// AF-03 row 5 (profile property names colliding with the app's own) is a pointer to AN-03
		// row 4 — and that pointer used to run in a circle, because Amplitude's check pointed back
		// here. It is asserted once, at the end of this file (T24), where the writing code lives.

		// ── AF-04 row 1 — the `-` placeholder belongs in the event only ──────────────────────
		// Executes `AppsFlyerService.swift:129-132`. T14 pins the event half (green: the fixed
		// payload needs every field present). T15 states the spec for the two profile writes and
		// is RED — `:131` and `:132` both write the same placeholder today.
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
		// Executes `AppsFlyerService.swift:112-115`. Green: `:112` returns before `:116`.
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
		// The other half of the row — the contradiction must leave a trace visible outside Xcode —
		// is NOT covered, same reason as AF-01 row 1: `:113` writes through `debugLog`.

		// ── AF-04 row 3 — the deep-link event has a fixed eleven-field shape ─────────────────
		// Executes `AppsFlyerService.swift:129-130` with two of the eleven fields present. The
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
		// Executes `AppsFlyerService.swift:117-118` (T18) and `:119-120` (T19). The row's third
		// branch — `.found` with no content, `:111-115` — is covered once, by T16 above.
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
		// Executes `AppsFlyerService.swift:131-132` twice. This row pins a decision, not a defect:
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
		// Executes `AppsFlyerService.swift:53-55` with the SDK swallowing the block. RED: `:54`
		// is the only place `restorationHandler` is ever called, so nothing answers the system and
		// the app sits on its launch screen.
		AppsFlyerLib.reset()
		AppsFlyerLib.continueBehaviour = .neverCallsBlock
		let t21Service = AppsFlyerService(analytics: FakeAnalytics(), adapty: FakeAdapty())
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
		// Executes `AppsFlyerService.swift:54` with a mixed array. RED: the cast is applied to the
		// array as a whole, so a single `String` among the objects turns the entire answer into
		// nil and the good object never reaches the system.
		AppsFlyerLib.reset()
		let t22Restorer = FakeRestorer()
		AppsFlyerLib.continueBehaviour = .callsWith([t22Restorer, "not a restoring object"])
		let t22Service = AppsFlyerService(analytics: FakeAnalytics(), adapty: FakeAdapty())
		var t22Received: [UIUserActivityRestoring]?
		t22Service.handleContinue(NSUserActivity(activityType: "check.continue")) { restoring in
			t22Received = restoring
		}
		check(
			t22Received?.count == 1 && t22Received?.first === t22Restorer,
			"T22 AF-05 row 2: a mixed answer must reach the system as exactly 1 object — the "
				+ "conforming one — got \(String(describing: t22Received?.count)) object(s)"
		)

		// AF-05 row 3 (the forwards are silent while the layer is off) is NOT covered: the gate it
		// names lives at `IntegrationKit.swift:80-85`/`:124`/`:129`, and this check does not
		// compile `IntegrationKit.swift` — it would drag in Adapty, Amplitude, StoreKit and
		// Premium. Calling `handleContinue`/`handleOpen` straight on the service instead takes the
		// opposite branch: neither method has a gate of its own, so both do reach the SDK. Its
		// other half — the first forward through a disabled layer must leave a trace visible
		// outside Xcode — has no trace at all to observe, same reason as AF-01 row 1.

		// AF-06 row 1 (a failed attribution must leave a trace carrying the error's domain and
		// code) is NOT covered: `:95` and `:103` write through `debugLog` and flatten the error to
		// `localizedDescription` on the way. Both the channel and the lost fields are invisible
		// from inside the process — same reason as AF-01 row 1.

		// AF-06 row 2 (the legacy open-attribution callback discards its data) is covered by T23
		// below as far as it can be: its assert — 0 events, 0 profiles, 0 Adapty writes — is
		// exactly T23's, so it is made once. Its remaining half, a trace carrying what arrived, is
		// NOT covered for the same reason as AF-06 row 1.

		// ── AF-06 row 3 — all three failure/legacy callbacks stay silent ─────────────────────
		// Executes `AppsFlyerService.swift:94-96`, `:98-100` and `:102-104` on one instance. Green
		// today, and that is the point: the silence is a requirement, and until now nothing
		// asserted it, so a side effect added into any of the three would have passed unnoticed.
		AppsFlyerLib.reset()
		let t23Analytics = FakeAnalytics()
		let t23Adapty = FakeAdapty()
		let t23Service = AppsFlyerService(analytics: t23Analytics, adapty: t23Adapty)
		t23Service.onConversionDataFail(NSError(domain: "AppsFlyer", code: -1009))
		t23Service.onAppOpenAttribution(["campaign": "x"])
		t23Service.onAppOpenAttributionFailure(NSError(domain: "AppsFlyer", code: -1001))
		check(
			t23Analytics.events.count == 0
				&& t23Analytics.userProperties.count == 0
				&& t23Adapty.attributionData.count == 0
				&& t23Adapty.profileValues.count == 0,
			"T23 AF-06 row 3: the three failure/legacy callbacks must log 0 events, 0 analytics "
				+ "profiles, 0 Adapty attributions and 0 Adapty profiles, got "
				+ "\(t23Analytics.events.count), \(t23Analytics.userProperties.count), "
				+ "\(t23Adapty.attributionData.count), \(t23Adapty.profileValues.count)"
		)

		// ── AN-03 row 4 / AF-03 row 5 — the package's profile properties must be its own ────
		// Executes `AppsFlyerService.swift:84-88`. Neither schema's check was covering this row:
		// AF-03 row 5 points at AN-03 row 4 and AN-03 row 4 points back here, so the pointer went
		// in a circle and nobody asserted it. The code that writes the names lives in this file's
		// subject, so the assert belongs here. RED: all three names go into the shared profile
		// namespace unprefixed, and the app's own `status` or `campaign_name` and the package's
		// overwrite each other, last writer winning, with nothing to tell them apart. The `af_`
		// prefix itself is the implementation's choice — the two events already carry it — and
		// naming it is the only way to assert "recognizable" precisely.
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
		// the SDK itself (`minTimeBetweenSessions`, 5 s), not by a flag on our side. That makes
		// the once-per-process guard at `AppsFlyerService.swift:63-67` a defect rather than a
		// boundary. Two foreground signals with nothing reset in between — unlike T9, which
		// clears the flag on purpose — so the second one must still reach the SDK. Red.
		AppsFlyerLib.reset()
		let t25Service = AppsFlyerService(analytics: FakeAnalytics(), adapty: FakeAdapty())
		t25Service.configure(devKey: "key-1", appId: "id-1", deviceId: "device-1")
		postForegroundSignal()
		postForegroundSignal()
		NotificationCenter.default.removeObserver(t25Service)
		check(
			AppsFlyerLib.startCallCount == 2,
			"T25 AF-02 row 1: a second foreground return must start a new session, got "
				+ "\(AppsFlyerLib.startCallCount) start(s)"
		)

		if failures.isEmpty {
			print("AppsFlyerService (AF-01…AF-06): 25/25 OK")
		} else {
			print("\(failures.count) of 25 asserts FAILED:")
			for failure in failures {
				print("  - \(failure)")
			}
			exit(1)
		}
	}
}
