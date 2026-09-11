//
//  SinkAnalytics.swift
//  IntegrationKit
//
//  TM-07: the analytics layer of a test run. Amplitude is not built at all — the sink replaces the
//  sending, not the SDK — so nothing here can reach the live dashboard (TM-07 row 8).
//

import AppTrackingTransparency
import Foundation

final class SinkAnalytics: AnalyticsTracking {

	private static let tag = "TestMode"

	/// `nil` when the run gave no path. Every method below then does nothing, which is exactly what
	/// the layer does today under `isTestsRunning` — a unit run notices no difference (TM-01 row 7).
	private let sink: AnalyticsSink?

	init(sink: AnalyticsSink?) {
		self.sink = sink
	}

	func logEvent(_ event: String, properties: [String: Any]?) {
		sink?.record(event, properties: properties ?? [:])
	}

	func setUserProperties(_ properties: [String: Any]) {
		// Sorted so two runs of the same code write the same lines in the same order, for the same
		// reason the keys inside one line are sorted.
		for key in properties.keys.sorted() {
			guard let value = properties[key] else { continue }
			sink?.record(profileValue: String(describing: value), key: key)
		}
	}

	func setUserId(_ userId: String) {
		debugLog(tag: Self.tag, "analytics user id set to \(userId) — not written to the sink, it is identity rather than an event")
	}

	/// A fixed value rather than `nil`: the app forwards this id to its own backend and to other
	/// SDKs, and `nil` would make every test that checks identity assert against an absence.
	var deviceId: String? { "uitest-device" }

	func updateTrackingAuthorization(_ status: ATTrackingManager.AuthorizationStatus) {
		debugLog(tag: Self.tag, "ATT status \(status.rawValue) — nothing to forward, no SDK is up")
	}
}
