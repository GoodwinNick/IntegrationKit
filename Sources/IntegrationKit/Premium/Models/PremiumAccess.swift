//
//  PremiumAccess.swift
//  IntegrationKit
//

import Foundation

/// What Adapty says about the access level the app cares about.
public struct PremiumAccess: Equatable {
	public let isActive: Bool
	public let expiresAt: Date?

	public init(isActive: Bool, expiresAt: Date? = nil) {
		self.isActive = isActive
		self.expiresAt = expiresAt
	}
}
