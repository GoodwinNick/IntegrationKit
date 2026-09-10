//
//  AdaptyProfile.swift
//  IntegrationKit — Checks/Stubs
//
//  Stand-in for the one Adapty type the premium layer names: `AdaptyProfile`. Compiled into a
//  module called `Adapty`, so `PremiumService` and friends can be built and run outside Xcode
//  with their `import Adapty` untouched. Only the members `PremiumAccess+Adapty` reads are here;
//  if that mapping starts using a new field, this file has to grow with it.
//
//  KNOWN DIVERGENCE: upstream `profileId` is computed from a `userId` the initializer does not take
//  (`Profile/Entities/AdaptyProfile.swift:11-16`), so it cannot be set directly there. Here it is a
//  stored property with a default, which lets the checks that do not care about the id keep calling
//  `AdaptyProfile(accessLevels:)` unchanged. The type is the same — a non-optional `String`, which
//  is what makes `AdaptyService.profileId()` answer `nil` only when the PROFILE is missing.
//

import Foundation

public struct AdaptyProfile {
	public struct AccessLevel {
		public let id: String
		public let isActive: Bool
		public let isLifetime: Bool
		public let expiresAt: Date?

		public init(id: String, isActive: Bool, isLifetime: Bool, expiresAt: Date?) {
			self.id = id
			self.isActive = isActive
			self.isLifetime = isLifetime
			self.expiresAt = expiresAt
		}
	}

	public let profileId: String
	public let accessLevels: [String: AccessLevel]

	public init(profileId: String = "profile-stub", accessLevels: [String: AccessLevel]) {
		self.profileId = profileId
		self.accessLevels = accessLevels
	}
}
