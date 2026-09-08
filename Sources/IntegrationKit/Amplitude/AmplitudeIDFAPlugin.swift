//
//  AmplitudeIDFAPlugin.swift
//  IntegrationKit
//

import AdSupport
import AmplitudeSwift
import AppTrackingTransparency

/// Amplitude never collects the IDFA on its own — this enrichment attaches it to every event.
/// The device id is deliberately left untouched: it stays the app's own id shared with other SDKs.
nonisolated final class AmplitudeIDFAPlugin: EnrichmentPlugin {
	override func execute(event: BaseEvent) -> BaseEvent? {
		if ATTrackingManager.trackingAuthorizationStatus == .authorized {
			event.idfa = ASIdentifierManager.shared().advertisingIdentifier.uuidString
		}
		return event
	}
}
