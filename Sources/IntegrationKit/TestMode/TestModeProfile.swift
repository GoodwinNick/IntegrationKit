//
//  TestModeProfile.swift
//  IntegrationKit
//
//  The one place in the package that builds an `AdaptyProfile` of its own, and the only file the
//  test-mode layer binds to Adapty's own shape. It exists because the source protocol answers in
//  that type — `profile()` returns one, and the push carries one — and because `-adaptyLevelId` is
//  meaningless unless the answer really carries a level id for `PremiumAccess` to match against
//  (TM-03 row 5).
//
//  Built by decoding rather than by an initializer: `AdaptyProfile` has no public memberwise init
//  (`Profile/Entities/AdaptyProfile.swift`), and `init(from:)` is the only public way in. Keeping it
//  to one file is the point — an SDK that changes this shape changes this file and nothing else.
//

import Adapty
import Foundation

enum TestModeProfile {

	private static let tag = "TestMode"

	/// A profile with one active access level, or with none at all. `nil` expiry means lifetime —
	/// the same meaning `PremiumAccess.init(profile:levels:isVerified:)` gives it.
	static func make(levelId: String, isActive: Bool, expiresAt: Date?) -> AdaptyProfile? {
		var payload: [String: Any] = [
			"profile_id": "uitest-profile",
			"segment_hash": "uitest",
		]
		if isActive {
			var level: [String: Any] = [
				"id": levelId,
				"is_active": true,
				"vendor_product_id": "uitest.product",
				"store": "app_store",
				"activated_at": 0,
				"is_lifetime": expiresAt == nil,
				"will_renew": true,
				"is_in_grace_period": false,
				"is_refund": false,
			]
			if let expiresAt {
				level["expires_at"] = expiresAt.timeIntervalSince1970
			}
			payload["paid_access_levels"] = [levelId: level]
		}
		let decoder = JSONDecoder()
		decoder.dateDecodingStrategy = .secondsSince1970
		guard
			let data = try? JSONSerialization.data(withJSONObject: payload),
			let profile = try? decoder.decode(AdaptyProfile.self, from: data)
		else {
			// A silent `nil` here would read as "the source did not answer", which is a different
			// state entirely and the hardest kind of test failure to explain.
			ConfigurationIssues.shared.record(
				"test mode could not build a profile for level \"\(levelId)\" — the Adapty SDK changed its shape; see TestModeProfile",
				tag: Self.tag
			)
			return nil
		}
		return profile
	}
}
