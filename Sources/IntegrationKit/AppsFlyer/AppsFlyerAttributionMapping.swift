//
//  AppsFlyerAttributionMapping.swift
//  IntegrationKit
//
//  Pure transforms out of AppsFlyerService so they're checkable without linking the
//  AppsFlyerLib binary framework.
//

import Foundation

enum AppsFlyerAttributionMapping {

	/// Drops NSNull and any non-JSON-safe value so the result is safe to hand to an analytics
	/// event's properties.
	static func cleanedAttributionData(from installData: [AnyHashable: Any]) -> [String: Any] {
		var result: [String: Any] = [:]

		for (key, value) in installData {
			guard let key = key as? String else { continue }
			guard !(value is NSNull) else { continue }

			switch value {
				case is String, is Int, is Double, is Bool:
					result[key] = value
				default:
					continue
			}
		}

		return result
	}

	/// Deep-link click event flattened into the `af_didResolveDeepLink` event payload plus the
	/// `deep_link_value` used as a user/profile property.
	static func deepLinkPayload(deeplinkValue: String?, clickEvent: [String: Any]) -> (payload: [String: Any], dlvValue: String) {
		let dlvValue = deeplinkValue ?? "-"

		let payload: [String: Any] = [
			"deep_link_value":     dlvValue,
			"campaign":            clickEvent["campaign"] as? String ?? "",
			"campaign_id":         clickEvent["campaign_id"] as? String ?? "",
			"media_source":        clickEvent["media_source"] as? String ?? "",
			"match_type":          clickEvent["match_type"] as? String ?? "",
			"af_sub1":             clickEvent["af_sub1"] as? String ?? "",
			"af_sub2":             clickEvent["af_sub2"] as? String ?? "",
			"af_sub3":             clickEvent["af_sub3"] as? String ?? "",
			"af_sub4":             clickEvent["af_sub4"] as? String ?? "",
			"af_sub5":             clickEvent["af_sub5"] as? String ?? "",
			"click_http_referrer": clickEvent["click_http_referrer"] as? String ?? "",
		]

		return (payload, dlvValue)
	}
}
