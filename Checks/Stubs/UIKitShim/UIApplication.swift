//
//  UIApplication.swift
//  IntegrationKit — Checks/Stubs/UIKitShim
//
//  Stand-in for the handful of `UIApplication` symbols `AppsFlyerService`/`AppsFlyerServicing`
//  touch, compiled into a module called `UIKit`. Exists only because the checks compile natively
//  on macOS, where the real UIKit does not exist — `didBecomeActiveNotification` and
//  `OpenURLOptionsKey` are the only two members either file names, so that's all this has.
//

import Foundation

public enum UIApplication {
	public static let didBecomeActiveNotification = Notification.Name("UIApplicationDidBecomeActiveNotification")

	public struct OpenURLOptionsKey: Hashable {
		public let rawValue: String

		public init(rawValue: String) {
			self.rawValue = rawValue
		}
	}
}
