//
//  PremiumAccess.swift
//  IntegrationKit
//

import Foundation

/// What Adapty says about the access level the app cares about.
struct PremiumAccess: Equatable {
	let isActive: Bool
	let expiresAt: Date?

	init(isActive: Bool, expiresAt: Date? = nil) {
		self.isActive = isActive
		self.expiresAt = expiresAt
	}
}
