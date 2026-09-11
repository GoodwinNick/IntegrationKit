//
//  UIApplication.swift
//  IntegrationKit — Checks/Stubs/UIKitShim
//
//  Stand-in for the handful of `UIApplication` symbols `AppsFlyerService`/`AppsFlyerServicing`
//  touch, compiled into a module called `UIKit`. Exists only because the checks compile natively
//  on macOS, where the real UIKit does not exist — `didBecomeActiveNotification`,
//  `OpenURLOptionsKey` and `LaunchOptionsKey` are the only three members those files name, so
//  that's all this has.
//
//  `didBecomeActiveNotification` is no longer what starts a session — the SDK's own readiness
//  listener is — but `IntegrationKit.swift` still observes it for the premium barrier, so it stays.
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

	/// Only ever passed through — the package hands the whole dictionary to the SDK without reading
	/// a key out of it, so the shim needs nothing but a hashable stand-in.
	public struct LaunchOptionsKey: Hashable {
		public let rawValue: String

		public init(rawValue: String) {
			self.rawValue = rawValue
		}
	}
}
