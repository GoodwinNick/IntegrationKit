//
//  AmplitudeAnalytics.swift
//  IntegrationKit
//

import AmplitudeSwift
import AppTrackingTransparency
import Foundation

public final class AmplitudeAnalytics: AnalyticsTracking {

	private static let firstOpenTrackedKey = "IntegrationKit.amplitude.firstOpenTracked"

	private var amplitude: Amplitude?

	public init() {}

	public func configure(apiKey: String, deviceId: String, firstOpenEvent: String? = nil) {
		guard !apiKey.isEmpty else { return }
		amplitude = Amplitude(configuration: Configuration(apiKey: apiKey))
		// User id goes in before the first event, so even the first event carries it.
		setUserId(deviceId)
		trackFirstOpenOnce(event: firstOpenEvent)
	}

	public func setUserId(_ userId: String) {
		amplitude?.setUserId(userId: userId)
	}

	public var deviceId: String? {
		amplitude?.getDeviceId()
	}

	public func logEvent(_ event: String, properties: [String: Any]? = nil) {
		debugLog("LOG EVENT \(event).   Properties: \(String(describing: properties ?? [:]))")
		amplitude?.track(eventType: event, eventProperties: properties)
	}

	public func setUserProperties(_ properties: [String: Any]) {
		amplitude?.identify(userProperties: properties)
	}

	public func updateTrackingAuthorization(_ status: ATTrackingManager.AuthorizationStatus) {
		if status == .authorized {
			amplitude?.add(plugin: AmplitudeIDFAPlugin())
		}
	}

	private func trackFirstOpenOnce(event: String?) {
		guard !UserDefaults.standard.bool(forKey: Self.firstOpenTrackedKey) else { return }
		UserDefaults.standard.set(true, forKey: Self.firstOpenTrackedKey)
		let environment = Bundle.main.appStoreReceiptURL?.lastPathComponent != "sandboxReceipt" ? "production" : "sandbox"
		amplitude?.identify(userProperties: ["environment": environment])
		if let event {
			logEvent(event)
		}
	}
}
