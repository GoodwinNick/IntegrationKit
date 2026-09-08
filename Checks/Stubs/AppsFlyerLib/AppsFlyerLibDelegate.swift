//
//  AppsFlyerLibDelegate.swift
//  IntegrationKit — Checks/Stubs/AppsFlyerLib
//
//  Stand-in for `AppsFlyerLibDelegate` (AppsFlyerLib 7.0.x). `@objc`/`NSObjectProtocol`-bound
//  because the real SDK stores its delegate as a plain Objective-C `weak` reference — `weak var
//  delegate: AppsFlyerLibDelegate?` on `AppsFlyerLib` needs a class-bound protocol either way, and
//  the real one happens to be `@objc`. `AppsFlyerService` (an `NSObject` subclass) satisfies this
//  without marking its own methods `@objc`: the compiler infers that automatically for members
//  that witness an `@objc` protocol on an `NSObject` subclass.
//

import Foundation

@objc public protocol AppsFlyerLibDelegate: NSObjectProtocol {
	func onConversionDataSuccess(_ conversionInfo: [AnyHashable: Any])
	func onConversionDataFail(_ error: Error)
	func onAppOpenAttribution(_ attributionData: [AnyHashable: Any])
	func onAppOpenAttributionFailure(_ error: Error)
}
