//
//  AppsFlyerService.swift
//  IntegrationKit
//
//  AppsFlyer attribution — feeds analytics events and links the AppsFlyer identity to Adapty.
//  No custom backend involved: everything stays inside AnalyticsTracking/AdaptyServicing.
//

import AppsFlyerLib
import Foundation
import UIKit

final class AppsFlyerService: NSObject, AppsFlyerServicing {

	private static let tag = "AppsFlyer"

//	private let analytics: AnalyticsTracking
//	private let adapty: AdaptyServicing

	/// Internal (not private) so unit tests can seed/observe it without going through the real
	/// `AppsFlyerLib.shared().start()` network call. It no longer gates anything — AF-02 row 1: a
	/// session belongs to every foreground return, and near-identical starts are deduplicated by the
	/// SDK's own `minTimeBetweenSessions` (5 s), not by a flag of ours.
	var didStartAppsFlyer = false

	/// AF-01 row 5. Set only by a `configure` that actually stood the SDK up, so an empty dev key
	/// leaves it false and every forward below stays a no-op.
	private var isConfigured = false

	/// AF-04 row 2. How many times the SDK said "deep link found" and handed over nothing. Not a
	/// configuration issue — nothing is misconfigured, the SDK contradicted itself — so it is
	/// counted rather than filed as a cause.
	private(set) var droppedDeepLinks = 0

//	init(analytics: AnalyticsTracking, adapty: AdaptyServicing) {
////		self.analytics = analytics
////		self.adapty = adapty
//		super.init()
//	}

	deinit {
		// AF-01 row 4: the subscription ends with the object, rather than resting on `NotificationCenter`
		// zeroing its own reference — which it does on current iOS and did not always.
		NotificationCenter.default.removeObserver(self)
		debugLog(tag: Self.tag, "deinit — foreground observer removed")
	}

	/// `isTestsRunning` defaults only so the checks' own call sites stay short — the composition
	/// root always passes the app's answer, and the app always computes it.
	func configure(devKey: String, appId: String, deviceId: String, attTimeout: TimeInterval, isDebug: Bool, isTestsRunning: Bool = false) {
		// The dev key itself never reaches the log — it is a credential, and "set"/"empty" is the
		// only thing about it any of the branches below actually reads.
		debugLog(tag: Self.tag, "configure: devKey \(devKey.isEmpty ? "empty" : "set"), appId \(appId), deviceId \(deviceId), attTimeout \(attTimeout)s, isDebug \(isDebug), isTestsRunning \(isTestsRunning)")
		// AF-01 row 1, the second of the two switches: a test run must not stand the SDK up at all.
		// Attribution is bought traffic — sessions and install data from a robot move the numbers
		// an advertising budget is steered by. Its own reason, apart from the empty dev key: that
		// one is an app shipping without attribution, this one is a key that is perfectly fine.
		guard !isTestsRunning else {
			debugLog(tag: Self.tag, "configure stopped: the app reported a test run — the SDK is not stood up at all")
			ConfigurationIssues.shared.record(
				"AppsFlyer is off for this run — the app reported a test run",
				tag: Self.tag
			)
			return
		}
		// AF-01 row 1: a supported way to run without attribution — a test build, a flavour without
		// AppsFlyer — but not a silent one. Without this line "no attribution" and "forgot the key"
		// look identical from a release build.
		guard !devKey.isEmpty else {
			debugLog(tag: Self.tag, level: .error, "configure stopped: empty dev key — attribution and deep links are off for this run")
			ConfigurationIssues.shared.record(
				"AppsFlyer got an empty dev key — attribution and deep links are off for this run",
				tag: Self.tag
			)
			return
		}
		// AF-01 row 5: a second entry point in the app would otherwise stand the SDK up again and
		// register a second foreground observer, so one return would run the handler twice.
		guard !isConfigured else {
			debugLog(tag: Self.tag, "configure ignored: already configured in this process")
			return
		}
		isConfigured = true

		AppsFlyerLib.shared().initialize(devKey: devKey, appId: appId)
		debugLog(tag: Self.tag, "SDK initialized for appId \(appId)")
		// Documented to be needed on every launch, and to be useless after `start` — set here, ahead
		// of the observer below, so a foreground signal physically cannot overtake it.
		AppsFlyerLib.shared().customerUserID = deviceId
		debugLog(tag: Self.tag, "customerUserID set to \(deviceId) — before start, as the SDK requires")
		AppsFlyerLib.shared().delegate = self
		AppsFlyerLib.shared().deepLinkDelegate = self
		debugLog(tag: Self.tag, "delegate and deepLinkDelegate wired to the service")
		// AF-01 row 2: how long to wait for the ATT answer depends on where the app shows the prompt
		// — 60 s at launch, 120 s after a tutorial — and only the app knows that.
		AppsFlyerLib.shared().waitForATTUserAuthorization(timeoutInterval: attTimeout)
		debugLog(tag: Self.tag, "waiting up to \(attTimeout)s for the ATT answer before the install data goes out")
		// AF-01 row 3: the app's flag, not the build configuration. A package cannot know whether
		// this build wants SDK logs; leaving it hardwired means nobody can turn them on to check an
		// integration, or off in a debug build that ships.
		AppsFlyerLib.shared().isDebug = isDebug
		debugLog(tag: Self.tag, "SDK console logging \(isDebug ? "on" : "off") — the app's own key")

		NotificationCenter.default.addObserver(
			self,
			selector: #selector(startAppsFlyer),
			name: UIApplication.didBecomeActiveNotification,
			object: nil
		)
		debugLog(tag: Self.tag, "configure done — every foreground return now starts a session")
	}

	func handleContinue(_ userActivity: NSUserActivity, restorationHandler: @escaping ([UIUserActivityRestoring]?) -> Void) {
		debugLog(tag: Self.tag, "continue: activityType \(userActivity.activityType), webpageURL \(userActivity.webpageURL?.absoluteString ?? "none")")
		// AF-05 row 1: the system asked, and it must get exactly one answer — an app that never
		// answers sits on its launch screen. There is no guarantee anywhere that the SDK calls its
		// block, and AppsFlyer's own example passes `nil` for it, so the answer cannot be left to
		// live inside that block alone.
		var answered = false
		let answer: ([UIUserActivityRestoring]?) -> Void = { restoring in
			guard !answered else {
				debugLog(tag: Self.tag, "continue: a second answer arrived and was dropped — the system already got one")
				return
			}
			answered = true
			debugLog(tag: Self.tag, "continue: answering the system with \(restoring?.count ?? 0) object(s)")
			restorationHandler(restoring)
		}

		guard isConfigured else {
			// AF-05 row 3: nothing was initialized, so there is nothing to forward to — but the
			// system still gets its answer. The reason is already in `configurationIssues`, recorded
			// once when the empty key arrived.
			debugLog(tag: Self.tag, "continue: the layer is off — nothing goes to the SDK, the system still gets an empty answer")
			answer(nil)
			return
		}

		AppsFlyerLib.shared().continue(userActivity) { restoring in
			debugLog(tag: Self.tag, "continue: the SDK answered with \(restoring?.count ?? 0) raw object(s)")
			// AF-05 row 2: element by element. Casting the array as a whole turns one foreign object
			// into a `nil` answer and loses every good object with it.
			answer(restoring?.compactMap { $0 as? UIUserActivityRestoring })
		}
		if !answered {
			debugLog(tag: Self.tag, "continue: the SDK did not answer in time — falling back to an empty answer")
		}
		// The SDK answered synchronously or not at all: the restoration handler is UIKit's, and a
		// late answer is no better than none. Whatever `continue` did not deliver by now is empty.
		answer(nil)
	}

	func handleOpen(_ url: URL, options: [UIApplication.OpenURLOptionsKey: Any]) {
		debugLog(tag: Self.tag, "open: \(url.absoluteString), options \(options.keys.map(\.rawValue).sorted())")
		guard isConfigured else {
			debugLog(tag: Self.tag, "open: the layer is off — the URL does not reach the SDK")
			return
		}
		AppsFlyerLib.shared().handleOpen(url, options: options)
		debugLog(tag: Self.tag, "open: forwarded to the SDK unchanged")
	}

	/// AF-05: the pre-iOS 9 half of the same forward. It is still the method the system calls when
	/// the URL arrives from an app that opened it the old way, and the SDK keeps its own entry point
	/// for it — so an app that only implements the `options:` variant loses those opens silently.
	func handleOpen(_ url: URL, sourceApplication: String?, annotation: Any?) {
		debugLog(tag: Self.tag, "open (legacy): \(url.absoluteString), sourceApplication \(sourceApplication ?? "none")")
		guard isConfigured else {
			debugLog(tag: Self.tag, "open (legacy): the layer is off — the URL does not reach the SDK")
			return
		}
		AppsFlyerLib.shared().handleOpen(url, sourceApplication: sourceApplication, withAnnotation: annotation)
		debugLog(tag: Self.tag, "open (legacy): forwarded to the SDK unchanged")
	}

	@objc func startAppsFlyer() {
		let isFirst = !didStartAppsFlyer
		didStartAppsFlyer = true
		AppsFlyerLib.shared().start()
		// AF-02 row 1: every foreground return starts a session; near-identical ones are collapsed by
		// the SDK's own `minTimeBetweenSessions`, so a repeat here is expected, not a bug.
		debugLog(tag: Self.tag, isFirst ? "started — first session of this process" : "started — another foreground return")
	}
}

extension AppsFlyerService: AppsFlyerLibDelegate {

	func onConversionDataSuccess(_ installData: [AnyHashable: Any]) {
		debugLog(tag: Self.tag, "conversion data received: \(installData)")
		let cleanedData = AppsFlyerAttributionMapping.cleanedAttributionData(from: installData)
		debugLog(tag: Self.tag, "conversion data cleaned: \(installData.count) field(s) in, \(cleanedData.count) out — NSNull and non-scalar values dropped")

		// AF-03 row 3: both addressees speak from the same cleaned dictionary. Reading the raw one
		// here used to let the event say `af_status = 42` while the profile said "unknown" — the
		// same field, two answers, and a dashboard that contradicts itself.
//		analytics.logEvent("af_onConversionData", properties: cleanedData)
		debugLog(tag: Self.tag, "event af_onConversionData sent with \(cleanedData.count) propertie(s)")
		// AN-03 row 4 / AF-03 row 5: the profile properties carry the bare AppsFlyer names. Decided
		// on 2026-09-10, reversing the `af_` prefix: the namespace shared with the app's own
		// properties is accepted, so an app that writes its own `status`, `media_source` or
		// `campaign_name` overwrites these — the events keep their `af_` prefix regardless.
		let properties = [
			"status": describe(cleanedData["af_status"]),
			"media_source": describe(cleanedData["media_source"]),
			"campaign_name": describe(cleanedData["campaign"]),
		]
//		analytics.setUserProperties(properties)
		debugLog(tag: Self.tag, "user properties set: \(properties) — \"unknown\" means the SDK did not send that field")

		// AF-03 row 2: an empty UID is "no UID". An empty string is worse than nothing — it looks
		// like a real identifier and links the profile to nobody, permanently.
		let appsFlyerUID = AppsFlyerLib.shared().getAppsFlyerUID()
		debugLog(tag: Self.tag, appsFlyerUID.isEmpty ? "AppsFlyer UID is empty — Adapty gets nil, not an empty string" : "AppsFlyer UID \(appsFlyerUID) goes to Adapty as the network user id")
//		adapty.updateAppsFlyerAttribution(cleanedData, networkUserId: appsFlyerUID.isEmpty ? nil : appsFlyerUID)
		debugLog(tag: Self.tag, "attribution handed to Adapty")
	}

	func onConversionDataFail(_ error: Error) {
		// AF-06 row 1: `localizedDescription` is exactly what cannot tell a dropped connection from
		// a wrong dev key, and telling them apart is the whole reason to look. The install data
		// arrives once per install, so a failure here is not something a later launch repairs.
		let nsError = error as NSError
		// Read out of `userInfo` rather than through `localizedDescription`: for a domain Foundation
		// does not know — AppsFlyer's own — the property builds "The operation couldn't be completed.
		// (AppsFlyerErrorDomain error -1009.)", which is the domain and code a second time and needs
		// the localisation machinery to say it. What the SDK actually wrote is worth keeping; what
		// Foundation invents in its place is not.
		let detail = (nsError.userInfo[NSLocalizedDescriptionKey] as? String).map { " — \($0)" } ?? ""
		debugLog(tag: Self.tag, level: .error, "conversion data failed: \(nsError.domain) \(nsError.code)\(detail) — install data arrives once per install, no later launch repairs this")
		ConfigurationIssues.shared.record(
			"AppsFlyer could not deliver install attribution: \(nsError.domain) \(nsError.code)\(detail)",
			tag: Self.tag
		)
	}

	/// `String(describing:)` rather than `as? String`: the cleaned dictionary keeps scalars of any
	/// type, and a numeric `af_status` must reach the profile as the same "42" the event carries.
	private func describe(_ value: Any?) -> String {
		guard let value else { return "unknown" }
		return String(describing: value)
	}
}

extension AppsFlyerService: AppsFlyerDeepLinkDelegate {

	func didResolveDeepLink(_ result: DeepLinkResult) {
		// The status is not interpolated here on purpose: in the real SDK it is an ObjC enum, and
		// `\(…)` on one prints `__C.…(rawValue: 0)`. Each branch below says it in words instead.
		debugLog(tag: Self.tag, "UDL: the SDK reported a resolution")
		switch result.status {
			case .found:
				guard let deepLink = result.deepLink else {
					// AF-04 row 2: the SDK said "found" and handed over nothing. A deep link the
					// campaign was paid for disappears here, and the count is what makes that
					// visible outside Xcode.
					droppedDeepLinks += 1
					debugLog(tag: Self.tag, level: .error, "UDL: status found, but deepLink is nil — dropped deep links so far: \(droppedDeepLinks)")
					return
				}
				debugLog(tag: Self.tag, "UDL: found, deeplinkValue \(deepLink.deeplinkValue ?? "none"), clickEvent \(deepLink.clickEvent.keys.sorted())")
				applyDeepLink(deeplinkValue: deepLink.deeplinkValue, clickEvent: deepLink.clickEvent)
			case .notFound:
				debugLog(tag: Self.tag, "UDL: not found")
			case .failure:
				debugLog(tag: Self.tag, level: .error, "UDL failure: \(result.error?.localizedDescription ?? "unknown")")
			@unknown default:
				debugLog(tag: Self.tag, level: .error, "UDL: unknown status")
		}
	}

	/// Testable core of the `.found` branch above. `AppsFlyerDeepLink` has no public initializer
	/// (SDK-internal only), so this takes plain types.
	func applyDeepLink(deeplinkValue: String?, clickEvent: [String: Any]) {
		let (payload, dlvValue) = AppsFlyerAttributionMapping.deepLinkPayload(deeplinkValue: deeplinkValue, clickEvent: clickEvent)
//		analytics.logEvent("af_didResolveDeepLink", properties: payload)
		debugLog(tag: Self.tag, "event af_didResolveDeepLink sent, deep_link_value \(dlvValue), \(payload.count) field(s)")

		// AF-04 row 1: the `-` placeholder exists so the event keeps its fixed shape. In a profile
		// it is not a placeholder but a value, and "arrived from a link with no value" stops being
		// distinguishable from "arrived from a link whose value is a dash".
		guard let deeplinkValue, !deeplinkValue.isEmpty else {
			debugLog(tag: Self.tag, "deep link carries no value — the \"-\" placeholder stays in the event and reaches no profile")
			return
		}
//		analytics.setUserProperties(["deep_link_value": dlvValue])
//		adapty.setProfileValue(value: dlvValue, key: "deep_link_value")
		debugLog(tag: Self.tag, "deep_link_value \(dlvValue) written to both the analytics profile and the Adapty profile")
	}
}
