//
//  AppsFlyerServicing.swift
//  IntegrationKit
//

import AppTrackingTransparency
import Foundation
import UIKit

protocol AppsFlyerServicing: AnyObject {
	/// devKey and appId are app-specific and never guessed by the package — the app decodes
	/// (or already holds) them and passes the plain values in. deviceId ties AppsFlyer to the
	/// same stable id Amplitude/Adapty use.
	///
	/// `attTimeout` is how long the install data is held waiting for the ATT answer. The holding is
	/// this layer's own since SDK 7.0, which deprecated the SDK-side wait with "the SDK no longer
	/// manages ATT timing internally" and made ATT explicitly not a session-readiness condition. The
	/// limit still belongs to the app, because where it shows the prompt is what decides it — 60 s for
	/// one at launch, 120 s for one after a tutorial.
	///
	/// `launchOptions` is the AppDelegate's own dictionary, handed to the SDK untouched. A cold launch
	/// that came from a Universal Link carries it there, and without this the session is sent before
	/// that link resolves.
	/// `isDebug` and `isTestsRunning` are the app's own two keys: the first turns the SDK's console
	/// logging on, the second leaves the layer down altogether — a test run must not spend the
	/// advertising budget it is measured by (AF-01 rows 1 and 3). They are separate axes on
	/// purpose: gluing them together would drag SDK logs into every test run, or silence
	/// attribution in every debug build.
	///
	/// `resetsInstallInSandbox` asks for the install state to be wiped before the SDK is stood up, so
	/// a debug launch on a sandbox device attributes as a first install and a deferred deep link comes
	/// back. Asking is not enough on its own: it takes `isDebug` and a build that did not come from the
	/// App Store as well.
	func configure(devKey: String, appId: String, deviceId: String, attTimeout: TimeInterval, isDebug: Bool, isTestsRunning: Bool, resetsInstallInSandbox: Bool, launchOptions: [UIApplication.LaunchOptionsKey: Any]?)
	/// The app's ATT answer. The first session is held until this arrives — or until `attTimeout`
	/// runs out — because an install sent before the dialog is over carries no IDFA, and a click that
	/// needs ID matching is then attributed to nobody.
	func updateTrackingAuthorization(_ status: ATTrackingManager.AuthorizationStatus)
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
