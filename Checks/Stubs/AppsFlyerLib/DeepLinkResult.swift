//
//  DeepLinkResult.swift
//  IntegrationKit — Checks/Stubs/AppsFlyerLib
//
//  Stand-in for `DeepLinkResult` (AppsFlyerLib 7.0.x). Only the three fields
//  `AppsFlyerService.didResolveDeepLink` reads. Unlike the real SDK type, this one has a public
//  initializer so a check can build one directly instead of going through a real deep link.
//

import Foundation

public struct DeepLinkResult {
	public let status: DeepLinkResultStatus
	public let deepLink: AppsFlyerDeepLink?
	public let error: Error?

	public init(status: DeepLinkResultStatus, deepLink: AppsFlyerDeepLink? = nil, error: Error? = nil) {
		self.status = status
		self.deepLink = deepLink
		self.error = error
	}
}
