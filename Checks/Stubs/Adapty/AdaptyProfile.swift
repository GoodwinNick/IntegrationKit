//
//  AdaptyProfile.swift
//  IntegrationKit — Checks/Stubs
//
//  Stand-in for the one Adapty type the premium layer names: `AdaptyProfile`. Compiled into a
//  module called `Adapty`, so `PremiumService` and friends can be built and run outside Xcode
//  with their `import Adapty` untouched. Only the members `PremiumAccess+Adapty` reads are here;
//  if that mapping starts using a new field, this file has to grow with it.
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

	public let accessLevels: [String: AccessLevel]

	public init(accessLevels: [String: AccessLevel]) {
		self.accessLevels = accessLevels
	}
}
