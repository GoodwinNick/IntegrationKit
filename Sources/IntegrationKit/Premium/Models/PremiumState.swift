//
//  PremiumState.swift
//  IntegrationKit
//

import Foundation

/// The resolved premium state, cacheable across app launches.
struct PremiumState: Codable, Equatable {
	var isPremium: Bool
	var source: PremiumSource
	var isVerified: Bool
	var expiresAt: Date?
	var localPurchase: Bool

	init(isPremium: Bool, source: PremiumSource, isVerified: Bool, expiresAt: Date? = nil, localPurchase: Bool = false) {
		self.isPremium = isPremium
		self.source = source
		self.isVerified = isVerified
		self.expiresAt = expiresAt
		self.localPurchase = localPurchase
	}

	private enum CodingKeys: String, CodingKey {
		case isPremium
		case source
		case isVerified
		case expiresAt
		case localPurchase
	}

	/// A cache written by an already-shipped build has no `localPurchase` key. `decodeIfPresent`
	/// defaults it to `false` instead of throwing — Swift's synthesized `init(from:)` would throw
	/// on the missing key and silently wipe the user's cached premium on upgrade.
	init(from decoder: Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		isPremium = try container.decode(Bool.self, forKey: .isPremium)
		source = try container.decode(PremiumSource.self, forKey: .source)
		isVerified = try container.decode(Bool.self, forKey: .isVerified)
		expiresAt = try container.decodeIfPresent(Date.self, forKey: .expiresAt)
		localPurchase = try container.decodeIfPresent(Bool.self, forKey: .localPurchase) ?? false
	}

	func isExpired(at now: Date) -> Bool {
		guard let expiresAt else { return false }
		return expiresAt <= now
	}

	static let free = PremiumState(isPremium: false, source: .none, isVerified: false, localPurchase: false)
}
