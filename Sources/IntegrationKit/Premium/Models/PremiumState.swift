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
	/// When the mark above was set. It has to live here, next to the mark, because a mark that
	/// survives a restart while its date does not would start ageing from zero on every launch —
	/// that is, never age at all (PM-03, "Стійкий стан").
	///
	/// Non-nil exactly when `localPurchase` is true, with one exception that lasts a single
	/// resolve: a cache written before 0.6.0 carries the mark without a date, and the resolver
	/// stamps it with the current moment rather than treating it as ancient.
	var localPurchaseAt: Date?

	init(isPremium: Bool, source: PremiumSource, isVerified: Bool, expiresAt: Date? = nil, localPurchase: Bool = false, localPurchaseAt: Date? = nil) {
		self.isPremium = isPremium
		self.source = source
		self.isVerified = isVerified
		self.expiresAt = expiresAt
		self.localPurchase = localPurchase
		self.localPurchaseAt = localPurchaseAt
	}

	private enum CodingKeys: String, CodingKey {
		case isPremium
		case source
		case isVerified
		case expiresAt
		case localPurchase
		case localPurchaseAt
	}

	/// A cache written by an already-shipped build has no `localPurchase` key, and one written
	/// before 0.6.0 has no `localPurchaseAt`. `decodeIfPresent` defaults them instead of throwing —
	/// Swift's synthesized `init(from:)` would throw on the missing key and silently wipe the
	/// user's cached premium on upgrade.
	init(from decoder: Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		isPremium = try container.decode(Bool.self, forKey: .isPremium)
		source = try container.decode(PremiumSource.self, forKey: .source)
		isVerified = try container.decode(Bool.self, forKey: .isVerified)
		expiresAt = try container.decodeIfPresent(Date.self, forKey: .expiresAt)
		localPurchase = try container.decodeIfPresent(Bool.self, forKey: .localPurchase) ?? false
		localPurchaseAt = try container.decodeIfPresent(Date.self, forKey: .localPurchaseAt)
	}

	func isExpired(at now: Date) -> Bool {
		guard let expiresAt else { return false }
		return expiresAt <= now
	}

	static let free = PremiumState(isPremium: false, source: .none, isVerified: false, localPurchase: false)
}
