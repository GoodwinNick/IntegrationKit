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
	/// `attTimeout` is how long the SDK holds the install data waiting for the ATT answer, and
	/// `isDebug` turns the SDK's own console logging on. Both are the app's calls: only it knows
	/// when the ATT prompt appears, and whether this build wants SDK logs.
	func configure(devKey: String, appId: String, deviceId: String, attTimeout: TimeInterval, isDebug: Bool)
	/// Forwards `application(_:continue:restorationHandler:)` from AppDelegate into the SDK.
	func handleContinue(_ userActivity: NSUserActivity, restorationHandler: @escaping ([UIUserActivityRestoring]?) -> Void)
	/// Forwards `application(_:open:options:)` from AppDelegate into the SDK.
	func handleOpen(_ url: URL, options: [UIApplication.OpenURLOptionsKey: Any])
	/// How many deep links the SDK reported as found and then handed over empty. Not a
	/// configuration issue — nothing is misconfigured, the SDK contradicted itself — so it is
	/// counted rather than filed as a cause. Surfaced by `IntegrationKit.droppedDeepLinks`,
	/// because a trace only `debugLog` can show is a trace nobody sees in a shipping build.
	var droppedDeepLinks: Int { get }
}
