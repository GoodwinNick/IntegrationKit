//
//  AnalyticsTracking.swift
//  IntegrationKit
//

import AppTrackingTransparency
import Foundation

/// The app's analytics surface — Amplitude behind it, reached as `IntegrationKit.analytics`. The
/// layer is already configured by the time the app holds one, and it never configures itself twice:
/// the composition root owns that call. A run the app reported as a test run, and an empty API key,
/// both leave the layer down for the whole run — nothing below is sent, and `deviceId` stays `nil`.
public protocol AnalyticsTracking: AnyObject {
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
	/// Logs an event carrying no properties — the common case.
	func logEvent(_ event: String) {
		logEvent(event, properties: nil)
	}
}
