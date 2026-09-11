//
//  AppsFlyerServicing.swift
//  IntegrationKit
//

import Foundation
import UIKit

protocol AppsFlyerServicing: AnyObject {
	/// devKey and appId are app-specific and never guessed by the package — the app decodes
	/// (or already holds) them and passes the plain values in. deviceId ties AppsFlyer to the
	/// same stable id Amplitude/Adapty use.
	///
	/// `attTimeout` is how long the SDK holds the install data waiting for the ATT answer.
	/// `isDebug` and `isTestsRunning` are the app's own two keys: the first turns the SDK's console
	/// logging on, the second leaves the layer down altogether — a test run must not spend the
	/// advertising budget it is measured by (AF-01 rows 1 and 3). They are separate axes on
	/// purpose: gluing them together would drag SDK logs into every test run, or silence
	/// attribution in every debug build.
	func configure(devKey: String, appId: String, deviceId: String, attTimeout: TimeInterval, isDebug: Bool, isTestsRunning: Bool)
	/// Forwards `application(_:continue:restorationHandler:)` from AppDelegate into the SDK.
	func handleContinue(_ userActivity: NSUserActivity, restorationHandler: @escaping ([UIUserActivityRestoring]?) -> Void)
	/// Forwards `application(_:open:options:)` from AppDelegate into the SDK.
	func handleOpen(_ url: URL, options: [UIApplication.OpenURLOptionsKey: Any])
	/// Forwards the pre-iOS 9 `application(_:open:sourceApplication:annotation:)` from AppDelegate
	/// into the SDK's own entry point for it. Both variants exist because the system still calls the
	/// legacy one, and an app that only forwards the `options:` one loses those opens silently.
	func handleOpen(_ url: URL, sourceApplication: String?, annotation: Any?)
	/// How many deep links the SDK reported as found and then handed over empty. Not a
	/// configuration issue — nothing is misconfigured, the SDK contradicted itself — so it is
	/// counted rather than filed as a cause. Surfaced by `IntegrationKit.droppedDeepLinks`,
	/// because a trace only `debugLog` can show is a trace nobody sees in a shipping build.
	var droppedDeepLinks: Int { get }
}
