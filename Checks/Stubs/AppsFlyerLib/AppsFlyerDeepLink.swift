//
//  AppsFlyerDeepLink.swift
//  IntegrationKit — Checks/Stubs/AppsFlyerLib
//
//  Stand-in for `AppsFlyerDeepLink` (AppsFlyerLib 7.0.x). Only the two fields
//  `AppsFlyerService.didResolveDeepLink` reads. Unlike the real SDK type, this one has a public
//  initializer so a check can build one directly instead of going through a real deep link.
//

import Foundation

public struct AppsFlyerDeepLink {
	public let deeplinkValue: String?
	public let clickEvent: [String: Any]

	public init(deeplinkValue: String?, clickEvent: [String: Any] = [:]) {
		self.deeplinkValue = deeplinkValue
		self.clickEvent = clickEvent
	}
}
