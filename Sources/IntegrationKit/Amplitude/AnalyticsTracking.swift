//
//  AnalyticsTracking.swift
//  IntegrationKit
//

import AppTrackingTransparency
import Foundation

public protocol AnalyticsTracking: AnyObject {
	/// `firstOpenEvent` is logged once per install, under the package's own gate. `isTestsRunning`
	/// is the app's own answer to "is this a test run" — the layer does not start at all when it is
	/// true, and the gate above is left unspent (AN-01 rows 3 and 8).
	func configure(apiKey: String, deviceId: String, firstOpenEvent: String?, isTestsRunning: Bool)
	/// Logs an event by name, optionally with properties.
	func logEvent(_ event: String, properties: [String: Any]?)
	/// Merges these into the current Amplitude user profile.
	func setUserProperties(_ properties: [String: Any])
	/// Ties analytics to the app's own stable id so other SDKs describe the same user.
	func setUserId(_ userId: String)
	/// Amplitude's own device id — nil until configured.
	var deviceId: String? { get }
	/// Forwards the ATT answer to SDKs that don't read it themselves (Amplitude IDFA).
	func updateTrackingAuthorization(_ status: ATTrackingManager.AuthorizationStatus)
}

public extension AnalyticsTracking {
	func logEvent(_ event: String) {
		logEvent(event, properties: nil)
	}
}
