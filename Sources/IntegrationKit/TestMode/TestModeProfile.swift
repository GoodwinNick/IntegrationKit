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

	/// A profile with the given access levels active, all with the same expiry, or with none at all
	/// (empty `levelIds` is a denial). `nil` expiry means lifetime — the same meaning
	/// `PremiumAccess.init(profile:levels:isVerified:)` gives it. TM-10 row 4: each level carries
	/// every key, so two levels decode as two.
	///
	/// TM-09: `subscriptions` are the product ids reported as active subscriptions next to the level.
	/// Each one carries every key the SDK's own `Subscription` requires — one missing and the whole
	/// decode fails, taking the level down with it (TM-09 row 4). The level and the subscriptions are
	/// independent here, as they are in a real profile: the verdict reads the level alone.
	static func make(levelIds: Set<String>, expiresAt: Date?, subscriptions: Set<String> = []) -> AdaptyProfile? {
		var payload: [String: Any] = [
			"profile_id": "uitest-profile",
			"segment_hash": "uitest",
		]
		if !subscriptions.isEmpty {
			payload["subscriptions"] = Dictionary(uniqueKeysWithValues: subscriptions.map { ($0, subscription(productId: $0)) })
		}
		if !levelIds.isEmpty {
			payload["paid_access_levels"] = Dictionary(uniqueKeysWithValues: levelIds.map { ($0, level(id: $0, expiresAt: expiresAt)) })
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
				"test mode could not build a profile for level(s) \(levelIds.sorted()) — the Adapty SDK changed its shape; see TestModeProfile",
				tag: Self.tag
			)
			return nil
		}
		return profile
	}

	/// One active access level as the server sends it.
	private static func level(id: String, expiresAt: Date?) -> [String: Any] {
		var level: [String: Any] = [
			"id": id,
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
		return level
	}

	/// One active subscription as the server sends it. The key names are the SDK's
	/// (`AdaptyProfile.Subscription.swift`, `CodingKeys`); the optional ones are left out.
	private static func subscription(productId: String) -> [String: Any] {
		[
			"store": "app_store",
			"vendor_product_id": productId,
			"vendor_transaction_id": "uitest.transaction.\(productId)",
			"vendor_original_transaction_id": "uitest.transaction.\(productId)",
			"is_active": true,
			"is_lifetime": false,
			"activated_at": 0,
			"is_in_grace_period": false,
			"is_sandbox": true,
			"is_refund": false,
			"will_renew": true,
		]
	}
}
