//
//  FirebaseApp.swift
//  IntegrationKit — Checks/Stubs/FirebaseCrashlytics
//
//  Stand-in for `FirebaseApp` (Firebase 12.x). Compiled into its own module called `FirebaseCore`
//  — `FirebaseIntegration.swift` imports `FirebaseCore` separately from `FirebaseCrashlytics`, so
//  the stub has to mirror that as two real modules, not one. Only `configure()`, the one call
//  `FirebaseIntegration.configure()` makes — counted, so CR-01 row 3 can tell a second
//  configuration from a no-op.
//

import Foundation

public enum FirebaseApp {
	public private(set) static var configureCallCount = 0

	public static func reset() {
		configureCallCount = 0
	}

	public static func configure() {
		configureCallCount += 1
	}
}
