//
//  AppsFlyerDeepLinkDelegate.swift
//  IntegrationKit — Checks/Stubs/AppsFlyerLib
//
//  Stand-in for `AppsFlyerDeepLinkDelegate` (AppsFlyerLib 7.0.x). A plain Swift protocol, not
//  `@objc` — unlike `AppsFlyerLibDelegate` — because `DeepLinkResult` is a Swift-only type an
//  Objective-C protocol could not carry.
//

import Foundation

public protocol AppsFlyerDeepLinkDelegate: AnyObject {
	func didResolveDeepLink(_ result: DeepLinkResult)
}
