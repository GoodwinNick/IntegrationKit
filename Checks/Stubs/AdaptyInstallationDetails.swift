//
//  AdaptyInstallationDetails.swift
//  IntegrationKit — Checks/Stubs
//
//  Stand-in for `AdaptyInstallationDetails` (Adapty 4.1.3,
//  `AdaptyAttribution/Entities/AdaptyInstallationDetails.swift:10-15`) — the payload of the two
//  installation callbacks Adapty Attribution fires.
//
//  The package leaves Adapty Attribution off (`adaptyAttributionEnabled` defaults to `false`), so
//  nothing here is expected to be called. The type exists only so `AdaptyDelegate` can declare all
//  five of its methods: a protocol that quietly omits one is worse than useless, because a service
//  that implements the missing method still COMPILES — Swift files it as an ordinary method and no
//  one ever calls it.
//
//  `Payload` is a marker: upstream it wraps whatever the dashboard attached to the install
//  (`AdaptyInstallationDetails.Payload.swift`), and no row asks what is inside it.
//

import Foundation

public struct AdaptyInstallationDetails {
	public struct Payload {
		public let jsonString: String?

		public init(jsonString: String? = nil) {
			self.jsonString = jsonString
		}
	}

	public let id: String?
	public let installTime: Date
	public let appLaunchCount: Int
	public let payload: Payload?

	public init(
		id: String? = nil,
		installTime: Date = Date(),
		appLaunchCount: Int = 1,
		payload: Payload? = nil
	) {
		self.id = id
		self.installTime = installTime
		self.appLaunchCount = appLaunchCount
		self.payload = payload
	}
}
