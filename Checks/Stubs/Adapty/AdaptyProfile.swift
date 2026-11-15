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

	/// PM-09 / TM-09. Carries exactly the keys upstream's own `Subscription` requires, none of them
	/// optional (`AdaptyProfile.Subscription.swift:121-145`) — a fake profile that forgot one fails to
	/// decode here the way it does against the real SDK, which is what TM-09 row 4 is about. Only
	/// `vendorProductId` and `isActive` are read by the package; the rest is here to be required.
	/// Decodable is synthesized on purpose: that is what makes every key mandatory.
	public struct Subscription: Decodable {
		public let store: String
		public let vendorProductId: String
		public let vendorTransactionId: String
		public let vendorOriginalTransactionId: String
		public let isActive: Bool
		public let isLifetime: Bool
		public let activatedAt: Date
		public let expiresAt: Date?
		public let isInGracePeriod: Bool
		public let isSandbox: Bool
		public let isRefund: Bool
		public let willRenew: Bool

		enum CodingKeys: String, CodingKey {
			case store
			case vendorProductId = "vendor_product_id"
			case vendorTransactionId = "vendor_transaction_id"
			case vendorOriginalTransactionId = "vendor_original_transaction_id"
			case isActive = "is_active"
			case isLifetime = "is_lifetime"
			case activatedAt = "activated_at"
			case expiresAt = "expires_at"
			case isInGracePeriod = "is_in_grace_period"
			case isSandbox = "is_sandbox"
			case isRefund = "is_refund"
			case willRenew = "will_renew"
		}

		/// For the checks that build a profile directly rather than through the decoder.
		public init(vendorProductId: String, isActive: Bool, isInGracePeriod: Bool = false, isRefund: Bool = false, expiresAt: Date? = nil) {
			store = "app_store"
			self.vendorProductId = vendorProductId
			vendorTransactionId = "transaction-stub"
			vendorOriginalTransactionId = "transaction-stub"
			self.isActive = isActive
			isLifetime = false
			activatedAt = Date(timeIntervalSince1970: 0)
			self.expiresAt = expiresAt
			self.isInGracePeriod = isInGracePeriod
			isSandbox = true
			self.isRefund = isRefund
			willRenew = true
		}
	}

	public let profileId: String
	public let accessLevels: [String: AccessLevel]
	/// The keys are product ids from the store, as upstream documents it.
	public let subscriptions: [String: Subscription]

	enum CodingKeys: String, CodingKey {
		case profileId = "profile_id"
		case accessLevels = "paid_access_levels"
		case subscriptions
	}

	public init(profileId: String = "profile-stub", accessLevels: [String: AccessLevel], subscriptions: [String: Subscription] = [:]) {
		self.profileId = profileId
		self.accessLevels = accessLevels
		self.subscriptions = subscriptions
	}

	/// Written by hand rather than synthesized: a profile with no active level carries no
	/// `paid_access_levels` key at all, and upstream reads that as an empty dictionary rather than an
	/// error.
	public init(from decoder: Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		profileId = try container.decode(String.self, forKey: .profileId)
		accessLevels = try container.decodeIfPresent([String: AccessLevel].self, forKey: .accessLevels) ?? [:]
		subscriptions = try container.decodeIfPresent([String: Subscription].self, forKey: .subscriptions) ?? [:]
	}
}
