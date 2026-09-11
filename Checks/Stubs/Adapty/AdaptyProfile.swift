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
//  `Decodable` is here because the test-mode layer has no other way in: upstream has no public
//  memberwise initializer at all, so `TestModeProfile` builds a profile by decoding one. The key
//  names and the "missing means empty" rule are copied from upstream's own `init(from:)`
//  (`AdaptyProfile.swift:108-127`, `AdaptyProfile.AccessLevel.swift:114-135`) so that the check
//  exercises the same JSON the shipping build does.
//

import Foundation

public struct AdaptyProfile: Decodable {
	public struct AccessLevel: Decodable {
		public let id: String
		public let isActive: Bool
		public let isLifetime: Bool
		public let expiresAt: Date?

		enum CodingKeys: String, CodingKey {
			case id
			case isActive = "is_active"
			case isLifetime = "is_lifetime"
			case expiresAt = "expires_at"
		}

		public init(id: String, isActive: Bool, isLifetime: Bool, expiresAt: Date?) {
			self.id = id
			self.isActive = isActive
			self.isLifetime = isLifetime
			self.expiresAt = expiresAt
		}
	}

	public let profileId: String
	public let accessLevels: [String: AccessLevel]

	enum CodingKeys: String, CodingKey {
		case profileId = "profile_id"
		case accessLevels = "paid_access_levels"
	}

	public init(profileId: String = "profile-stub", accessLevels: [String: AccessLevel]) {
		self.profileId = profileId
		self.accessLevels = accessLevels
	}

	/// Written by hand rather than synthesized: a profile with no active level carries no
	/// `paid_access_levels` key at all, and upstream reads that as an empty dictionary rather than an
	/// error.
	public init(from decoder: Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		profileId = try container.decode(String.self, forKey: .profileId)
		accessLevels = try container.decodeIfPresent([String: AccessLevel].self, forKey: .accessLevels) ?? [:]
	}
}
