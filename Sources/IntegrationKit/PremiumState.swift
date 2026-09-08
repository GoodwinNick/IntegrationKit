//
//  PremiumState.swift
//  IntegrationKit
//

import Foundation

/// The resolved premium state, cacheable across app launches.
public struct PremiumState: Codable, Equatable {
	public var isPremium: Bool
	public var source: PremiumSource
	public var isVerified: Bool
	public var expiresAt: Date?

	public init(isPremium: Bool, source: PremiumSource, isVerified: Bool, expiresAt: Date? = nil) {
		self.isPremium = isPremium
		self.source = source
		self.isVerified = isVerified
		self.expiresAt = expiresAt
	}

	public func isExpired(at now: Date) -> Bool {
		guard let expiresAt else { return false }
		return expiresAt <= now
	}

	public static let free = PremiumState(isPremium: false, source: .none, isVerified: false)
}
