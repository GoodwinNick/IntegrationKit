//
//  Crashlytics.swift
//  IntegrationKit — Checks/Stubs/FirebaseCrashlytics
//
//  Stand-in for the `Crashlytics` SDK class (Firebase 12.x). Compiled into a module called
//  `FirebaseCrashlytics` alongside `CrashReporter`/`FirebaseIntegration`'s
//  `import FirebaseCrashlytics`. `crashlytics()` always answers the same instance — same as the
//  real SDK's singleton — and every call is recorded on static vars, same idea as the `Adapty`
//  stub. `reset()` clears every recording; call it at the top of each row so one row's setup
//  cannot leak into the next.
//

import Foundation

public final class Crashlytics {
	private static let instance = Crashlytics()

	public static func crashlytics() -> Crashlytics {
		instance
	}

	public static private(set) var recordedErrors: [(domain: String, code: Int, userInfo: [String: Any]?)] = []
	public static private(set) var recordCallCount = 0
	/// `nil` means "never set" — CR-01 row 4 has to tell an explicit `true` from a flag nobody
	/// touched, and a plain `Bool` cannot say that.
	public static private(set) var collectionEnabled: Bool?
	/// The searchable half of a report. CR-02 row 1 turns on the difference between this and
	/// `userInfo`: only what lands here can be filtered in the dashboard.
	public static private(set) var customValues: [String: Any] = [:]

	public static func reset() {
		recordedErrors = []
		recordCallCount = 0
		collectionEnabled = nil
		customValues = [:]
	}

	private init() {}

	public func record(error: Error, userInfo: [String: Any]? = nil) {
		let nsError = error as NSError
		Crashlytics.recordCallCount += 1
		Crashlytics.recordedErrors.append((nsError.domain, nsError.code, userInfo))
	}

	public func setCrashlyticsCollectionEnabled(_ enabled: Bool) {
		Crashlytics.collectionEnabled = enabled
	}

	public func setCustomValue(_ value: Any, forKey key: String) {
		Crashlytics.customValues[key] = value
	}
}
