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
	func configure(devKey: String, appId: String, deviceId: String)
	/// Forwards `application(_:continue:restorationHandler:)` from AppDelegate into the SDK.
	func handleContinue(_ userActivity: NSUserActivity, restorationHandler: @escaping ([UIUserActivityRestoring]?) -> Void)
	/// Forwards `application(_:open:options:)` from AppDelegate into the SDK.
	func handleOpen(_ url: URL, options: [UIApplication.OpenURLOptionsKey: Any])
}
