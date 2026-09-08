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

	private let analytics: AnalyticsTracking
	private let adapty: AdaptyServicing

	/// Internal (not private) so unit tests can seed/observe the guard in `startAppsFlyer()`
	/// without going through the real `AppsFlyerLib.shared().start()` network call.
	var didStartAppsFlyer = false

	init(analytics: AnalyticsTracking, adapty: AdaptyServicing) {
		self.analytics = analytics
		self.adapty = adapty
		super.init()
	}

	func configure(devKey: String, appId: String, deviceId: String) {
		guard !devKey.isEmpty else {
			debugLog("[AppsFlyer] dev key is empty — SDK not started")
			return
		}

		AppsFlyerLib.shared().initialize(devKey: devKey, appId: appId)
		AppsFlyerLib.shared().customerUserID = deviceId
		AppsFlyerLib.shared().delegate = self
		AppsFlyerLib.shared().deepLinkDelegate = self
		AppsFlyerLib.shared().waitForATTUserAuthorization(timeoutInterval: 60)
		AppsFlyerLib.shared().isDebug = false

		NotificationCenter.default.addObserver(
			self,
			selector: #selector(startAppsFlyer),
			name: UIApplication.didBecomeActiveNotification,
			object: nil
		)
	}

	func handleContinue(_ userActivity: NSUserActivity, restorationHandler: @escaping ([UIUserActivityRestoring]?) -> Void) {
		// AppsFlyer's block param is untyped NSArray*, imported as `[Any]?` — bridged explicitly
		// instead of passing `restorationHandler` straight through, which type-checks as a
		// contravariant mismatch against `[UIUserActivityRestoring]?` and crashes the compiler.
		AppsFlyerLib.shared().continue(userActivity) { restoring in
			restorationHandler(restoring as? [UIUserActivityRestoring])
		}
	}

	func handleOpen(_ url: URL, options: [UIApplication.OpenURLOptionsKey: Any]) {
		AppsFlyerLib.shared().handleOpen(url, options: options)
	}

	@objc func startAppsFlyer() {
		guard !didStartAppsFlyer else {
			debugLog("[AppsFlyer] already started, skip")
			return
		}
		didStartAppsFlyer = true
		AppsFlyerLib.shared().start()
		debugLog("[AppsFlyer] started")
	}
}

extension AppsFlyerService: AppsFlyerLibDelegate {

	func onConversionDataSuccess(_ installData: [AnyHashable: Any]) {
		debugLog("[AppsFlyer] conversion data received: \(installData)")
		let cleanedData = AppsFlyerAttributionMapping.cleanedAttributionData(from: installData)

		let status = installData["af_status"] as? String ?? "unknown"
		let mediaSource = installData["media_source"] as? String ?? "unknown"
		let campaignName = installData["campaign"] as? String ?? "unknown"

		analytics.logEvent("af_onConversionData", properties: cleanedData)
		analytics.setUserProperties([
			"status": status,
			"media_source": mediaSource,
			"campaign_name": campaignName,
		])

		let appsFlyerUID = AppsFlyerLib.shared().getAppsFlyerUID()
		adapty.updateAppsFlyerAttribution(cleanedData, networkUserId: appsFlyerUID)
	}

	func onConversionDataFail(_ error: Error) {
		debugLog("[AppsFlyer] conversion data error: \(error.localizedDescription)")
	}

	func onAppOpenAttribution(_ attributionData: [AnyHashable: Any]) {
		debugLog("[AppsFlyer] app open attribution: \(attributionData)")
	}

	func onAppOpenAttributionFailure(_ error: Error) {
		debugLog("[AppsFlyer] app open attribution failure: \(error.localizedDescription)")
	}
}

extension AppsFlyerService: AppsFlyerDeepLinkDelegate {

	func didResolveDeepLink(_ result: DeepLinkResult) {
		switch result.status {
			case .found:
				guard let deepLink = result.deepLink else {
					debugLog("[AppsFlyer] UDL: status found, but deepLink is nil")
					return
				}
				applyDeepLink(deeplinkValue: deepLink.deeplinkValue, clickEvent: deepLink.clickEvent)
			case .notFound:
				debugLog("[AppsFlyer] UDL: not found")
			case .failure:
				debugLog("[AppsFlyer] UDL failure: \(result.error?.localizedDescription ?? "unknown")")
			@unknown default:
				debugLog("[AppsFlyer] UDL: unknown status")
		}
	}

	/// Testable core of the `.found` branch above. `AppsFlyerDeepLink` has no public initializer
	/// (SDK-internal only), so this takes plain types.
	func applyDeepLink(deeplinkValue: String?, clickEvent: [String: Any]) {
		let (payload, dlvValue) = AppsFlyerAttributionMapping.deepLinkPayload(deeplinkValue: deeplinkValue, clickEvent: clickEvent)
		analytics.logEvent("af_didResolveDeepLink", properties: payload)
		analytics.setUserProperties(["deep_link_value": dlvValue])
		adapty.setProfileValue(value: dlvValue, key: "deep_link_value")
	}
}
