//
//  FirebaseApp.swift
//  IntegrationKit — Checks/Stubs/FirebaseCrashlytics
//
//  Stand-in for `FirebaseApp` (Firebase 12.x). Compiled into its own module called `FirebaseCore`
//  — `FirebaseIntegration.swift` imports `FirebaseCore` separately from `FirebaseCrashlytics`, so
//  the stub has to mirror that as two real modules, not one. Only `configure()`, the one call
//  `FirebaseIntegration.configure()` makes.
//

import Foundation

public enum FirebaseApp {
	public static func configure() {}
}
