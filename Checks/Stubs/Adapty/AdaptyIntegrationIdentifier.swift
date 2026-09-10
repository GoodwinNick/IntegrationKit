//
//  AdaptyIntegrationIdentifier.swift
//  IntegrationKit — Checks/Stubs
//
//  Stand-in for `AdaptyIntegrationIdentifier` (Adapty 4.1.3,
//  `Profile/Entities/AdaptyIntegrationIdentifier.swift`). New in 4.x, and half of what
//  `updateAttribution(_:source:networkUserId:)` was cut into: the payload now goes through
//  `updateExternalAttribution`, and the JOIN KEY that ties it to the network's own user goes through
//  `setIntegrationIdentifier`. AD-06 row 10 is about the two halves being able to fail apart.
//
//  Only the three factories the package needs are here — `appsflyerId` (`:44-46`), `amplitudeUserId`
//  (`:28-30`) and `amplitudeDeviceId` (`:32-34`); the last two are where the profile-builder setters
//  that 4.1.3 deleted went. The other thirteen are one line each upstream and no row asks about them.
//
//  The `.trimmed` on `value` (`:17`) is reproduced, and it matters: it is what turns a whitespace-only
//  AppsFlyer id into an EMPTY join key rather than a rejected one. The SDK does not check for empty,
//  so `AdaptyService` has to.
//

import Foundation

public struct AdaptyIntegrationIdentifier: Hashable {
	public struct Key: RawRepresentable, Hashable {
		public let rawValue: String

		public init(rawValue: String) {
			self.rawValue = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
		}

		public static let amplitudeUserId = Key(rawValue: "amplitude_user_id")
		public static let amplitudeDeviceId = Key(rawValue: "amplitude_device_id")
		public static let appsflyerId = Key(rawValue: "appsflyer_id")
	}

	public let key: Key
	public let value: String

	public init(key: Key, value: String) {
		self.key = key
		self.value = value.trimmingCharacters(in: .whitespacesAndNewlines)
	}

	public static func amplitudeUserId(_ value: String) -> Self {
		.init(key: .amplitudeUserId, value: value)
	}

	public static func amplitudeDeviceId(_ value: String) -> Self {
		.init(key: .amplitudeDeviceId, value: value)
	}

	public static func appsflyerId(_ value: String) -> Self {
		.init(key: .appsflyerId, value: value)
	}
}
