//
//  PremiumAccess.swift
//  IntegrationKit
//

import Foundation

/// What Adapty says about the access level the app cares about.
struct PremiumAccess: Equatable {
	let isActive: Bool
	let expiresAt: Date?
	/// Whether this answer came from the network in this process. A profile the SDK pushed straight
	/// out of its own storage on activation is a memory of the last launch, not a check — and a
	/// stale "no premium" from disk must not read as a verified denial (AD-05 row 2).
	///
	/// Only ever narrows the answer: an unverified `isActive` still grants, an unverified denial
	/// does not close. Doubt goes to the user.
	let isVerified: Bool

	init(isActive: Bool, expiresAt: Date? = nil, isVerified: Bool = true) {
		self.isActive = isActive
		self.expiresAt = expiresAt
		self.isVerified = isVerified
	}
}
