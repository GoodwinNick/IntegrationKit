//
//  AppsFlyerAttributionCheck.swift
//  IntegrationKit
//
//  AppsFlyerAttributionMapping in four asserts. Pure, no SDK import, so a script is enough —
//  same pattern as PremiumResolverCheck.
//  Run:  ./Checks/appsflyer-attribution-check.sh
//

import Foundation

@main
enum AppsFlyerAttributionCheck {
	static func main() {
		// 1. NSNull and non-JSON-safe values (array, dict) are dropped; scalars kept.
		let raw: [AnyHashable: Any] = [
			"af_status": "Organic",
			"count": 3,
			"ratio": 1.5,
			"is_first_launch": true,
			"nothing": NSNull(),
			"nested": ["a": 1],
			42: "non-string key",
		]
		let cleaned = AppsFlyerAttributionMapping.cleanedAttributionData(from: raw)
		assert(cleaned.count == 4, "expected 4 scalar keys, got \(cleaned.count): \(cleaned)")
		assert(cleaned["af_status"] as? String == "Organic")
		assert(cleaned["count"] as? Int == 3)
		assert(cleaned["ratio"] as? Double == 1.5)
		assert(cleaned["is_first_launch"] as? Bool == true)
		assert(cleaned["nothing"] == nil, "NSNull must be dropped")
		assert(cleaned["nested"] == nil, "non-scalar value must be dropped")
		assert(cleaned["non-string key"] == nil, "non-String key must be dropped")

		// 2. Empty input stays empty.
		assert(AppsFlyerAttributionMapping.cleanedAttributionData(from: [:]).isEmpty)

		// 3. Nil deeplinkValue falls back to "-".
		let (emptyPayload, emptyDlv) = AppsFlyerAttributionMapping.deepLinkPayload(deeplinkValue: nil, clickEvent: [:])
		assert(emptyDlv == "-")
		assert(emptyPayload["deep_link_value"] as? String == "-")
		assert(emptyPayload["campaign"] as? String == "", "missing clickEvent keys must default to empty string")

		// 4. clickEvent fields flow through to the payload.
		let (payload, dlv) = AppsFlyerAttributionMapping.deepLinkPayload(
			deeplinkValue: "promo123",
			clickEvent: ["campaign": "spring_sale", "media_source": "facebook", "af_sub1": "vip"]
		)
		assert(dlv == "promo123")
		assert(payload["deep_link_value"] as? String == "promo123")
		assert(payload["campaign"] as? String == "spring_sale")
		assert(payload["media_source"] as? String == "facebook")
		assert(payload["af_sub1"] as? String == "vip")
		assert(payload["af_sub2"] as? String == "")

		print("AppsFlyerAttributionMapping: 4/4 OK")
	}
}
