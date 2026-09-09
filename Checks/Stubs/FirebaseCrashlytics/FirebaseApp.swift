//
//  FirebaseApp.swift
//  IntegrationKit — Checks/Stubs/FirebaseCrashlytics
//
//  Stand-in for `FirebaseApp` (Firebase 12.x). Compiled into its own module called `FirebaseCore`
//  — `FirebaseIntegration.swift` imports `FirebaseCore` separately from `FirebaseCrashlytics`, so
//  the stub has to mirror that as two real modules, not one.
//
//  A class, not an enum, because the two rows that need it need an instance: `app()` answers `nil`
//  until `configure()` has run and the same object afterwards — that is how the real SDK says "I am
//  not up yet" (CR-01 row 1) and the only way a wrapper can make a second configuration a no-op
//  without asking the app to remember (CR-01 row 3). `configureCallCount` still counts, because a
//  no-op has to be told from a second real configuration.
//

import Foundation

public final class FirebaseApp {
	public private(set) static var configureCallCount = 0
	private static var defaultApp: FirebaseApp?

	private init() {}

	public static func reset() {
		configureCallCount = 0
		defaultApp = nil
	}

	/// `nil` until `configure()` has run — the real SDK's answer to "is Firebase up".
	public static func app() -> FirebaseApp? {
		defaultApp
	}

	public static func configure() {
		configureCallCount += 1
		defaultApp = FirebaseApp()
	}
}
