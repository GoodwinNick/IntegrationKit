//
//  AdaptyPaywall.swift
//  IntegrationKit — Checks/Stubs
//
//  Stand-in for `AdaptyPaywall` (Adapty 2.10.x). Only `remoteConfig` is here — the one field
//  `AdaptyService`'s `getRemoteValue` reads.
//

import Foundation

public struct AdaptyPaywall {
	public let remoteConfig: [String: Any]?

	public init(remoteConfig: [String: Any]? = nil) {
		self.remoteConfig = remoteConfig
	}
}
