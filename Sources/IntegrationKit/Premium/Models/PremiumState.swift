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

	init(isPremium: Bool, source: PremiumSource, isVerified: Bool, expiresAt: Date? = nil) {
		self.isPremium = isPremium
		self.source = source
		self.isVerified = isVerified
		self.expiresAt = expiresAt
	}

	func isExpired(at now: Date) -> Bool {
		guard let expiresAt else { return false }
		return expiresAt <= now
	}

	static let free = PremiumState(isPremium: false, source: .none, isVerified: false)
}
