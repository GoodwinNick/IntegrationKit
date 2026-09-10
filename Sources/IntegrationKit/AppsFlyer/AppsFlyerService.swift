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

	private let analytics: AnalyticsTracking
	private let adapty: AdaptyServicing

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

	init(analytics: AnalyticsTracking, adapty: AdaptyServicing) {
		self.analytics = analytics
		self.adapty = adapty
		super.init()
	}

	deinit {
		// AF-01 row 4: the subscription ends with the object, rather than resting on `NotificationCenter`
		// zeroing its own reference — which it does on current iOS and did not always.
		NotificationCenter.default.removeObserver(self)
	}

	/// `isTestsRunning` defaults only so the checks' own call sites stay short — the composition
	/// root always passes the app's answer, and the app always computes it.
	func configure(devKey: String, appId: String, deviceId: String, attTimeout: TimeInterval, isDebug: Bool, isTestsRunning: Bool = false) {
		// AF-01 row 1, the second of the two switches: a test run must not stand the SDK up at all.
		// Attribution is bought traffic — sessions and install data from a robot move the numbers
		// an advertising budget is steered by. Its own reason, apart from the empty dev key: that
		// one is an app shipping without attribution, this one is a key that is perfectly fine.
		guard !isTestsRunning else {
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
			ConfigurationIssues.shared.record(
				"AppsFlyer got an empty dev key — attribution and deep links are off for this run",
				tag: Self.tag
			)
			return
		}
		// AF-01 row 5: a second entry point in the app would otherwise stand the SDK up again and
		// register a second foreground observer, so one return would run the handler twice.
		guard !isConfigured else { return }
		isConfigured = true

		AppsFlyerLib.shared().initialize(devKey: devKey, appId: appId)
		// Documented to be needed on every launch, and to be useless after `start` — set here, ahead
		// of the observer below, so a foreground signal physically cannot overtake it.
		AppsFlyerLib.shared().customerUserID = deviceId
		AppsFlyerLib.shared().delegate = self
		AppsFlyerLib.shared().deepLinkDelegate = self
		// AF-01 row 2: how long to wait for the ATT answer depends on where the app shows the prompt
		// — 60 s at launch, 120 s after a tutorial — and only the app knows that.
		AppsFlyerLib.shared().waitForATTUserAuthorization(timeoutInterval: attTimeout)
		// AF-01 row 3: the app's flag, not the build configuration. A package cannot know whether
		// this build wants SDK logs; leaving it hardwired means nobody can turn them on to check an
		// integration, or off in a debug build that ships.
		AppsFlyerLib.shared().isDebug = isDebug

		NotificationCenter.default.addObserver(
			self,
			selector: #selector(startAppsFlyer),
			name: UIApplication.didBecomeActiveNotification,
			object: nil
		)
	}

	func handleContinue(_ userActivity: NSUserActivity, restorationHandler: @escaping ([UIUserActivityRestoring]?) -> Void) {
		// AF-05 row 1: the system asked, and it must get exactly one answer — an app that never
		// answers sits on its launch screen. There is no guarantee anywhere that the SDK calls its
		// block, and AppsFlyer's own example passes `nil` for it, so the answer cannot be left to
		// live inside that block alone.
		var answered = false
		let answer: ([UIUserActivityRestoring]?) -> Void = { restoring in
			guard !answered else { return }
			answered = true
			restorationHandler(restoring)
		}

		guard isConfigured else {
			// AF-05 row 3: nothing was initialized, so there is nothing to forward to — but the
			// system still gets its answer. The reason is already in `configurationIssues`, recorded
			// once when the empty key arrived.
			answer(nil)
			return
		}

		AppsFlyerLib.shared().continue(userActivity) { restoring in
			// AF-05 row 2: element by element. Casting the array as a whole turns one foreign object
			// into a `nil` answer and loses every good object with it.
			answer(restoring?.compactMap { $0 as? UIUserActivityRestoring })
		}
		// The SDK answered synchronously or not at all: the restoration handler is UIKit's, and a
		// late answer is no better than none. Whatever `continue` did not deliver by now is empty.
		answer(nil)
	}

	func handleOpen(_ url: URL, options: [UIApplication.OpenURLOptionsKey: Any]) {
		guard isConfigured else { return }
		AppsFlyerLib.shared().handleOpen(url, options: options)
	}

	@objc func startAppsFlyer() {
		didStartAppsFlyer = true
		AppsFlyerLib.shared().start()
		debugLog(tag: Self.tag, "started")
	}
}

extension AppsFlyerService: AppsFlyerLibDelegate {

	func onConversionDataSuccess(_ installData: [AnyHashable: Any]) {
		debugLog(tag: Self.tag, "conversion data received: \(installData)")
		let cleanedData = AppsFlyerAttributionMapping.cleanedAttributionData(from: installData)

		// AF-03 row 3: both addressees speak from the same cleaned dictionary. Reading the raw one
		// here used to let the event say `af_status = 42` while the profile said "unknown" — the
		// same field, two answers, and a dashboard that contradicts itself.
		analytics.logEvent("af_onConversionData", properties: cleanedData)
		// AN-03 row 4 / AF-03 row 5: the profile properties carry the bare AppsFlyer names. Decided
		// on 2026-09-10, reversing the `af_` prefix: the namespace shared with the app's own
		// properties is accepted, so an app that writes its own `status`, `media_source` or
		// `campaign_name` overwrites these — the events keep their `af_` prefix regardless.
		analytics.setUserProperties([
			"status": describe(cleanedData["af_status"]),
			"media_source": describe(cleanedData["media_source"]),
			"campaign_name": describe(cleanedData["campaign"]),
		])

		// AF-03 row 2: an empty UID is "no UID". An empty string is worse than nothing — it looks
		// like a real identifier and links the profile to nobody, permanently.
		let appsFlyerUID = AppsFlyerLib.shared().getAppsFlyerUID()
		adapty.updateAppsFlyerAttribution(cleanedData, networkUserId: appsFlyerUID.isEmpty ? nil : appsFlyerUID)
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
		switch result.status {
			case .found:
				guard let deepLink = result.deepLink else {
					// AF-04 row 2: the SDK said "found" and handed over nothing. A deep link the
					// campaign was paid for disappears here, and the count is what makes that
					// visible outside Xcode.
					droppedDeepLinks += 1
					debugLog(tag: Self.tag, level: .error, "UDL: status found, but deepLink is nil")
					return
				}
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
		analytics.logEvent("af_didResolveDeepLink", properties: payload)

		// AF-04 row 1: the `-` placeholder exists so the event keeps its fixed shape. In a profile
		// it is not a placeholder but a value, and "arrived from a link with no value" stops being
		// distinguishable from "arrived from a link whose value is a dash".
		guard let deeplinkValue, !deeplinkValue.isEmpty else { return }
		analytics.setUserProperties(["deep_link_value": dlvValue])
		adapty.setProfileValue(value: dlvValue, key: "deep_link_value")
	}
}
