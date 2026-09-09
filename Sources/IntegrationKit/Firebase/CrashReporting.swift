//
//  CrashReporting.swift
//  IntegrationKit
//

import Foundation

public protocol CrashReporting {
	func recordNonFatal(_ tag: String, _ error: Error, _ info: [String: Any])

	/// Reports that never reached Crashlytics because Firebase was never brought up. Anything but
	/// zero means `FirebaseIntegration.configure()` was not called — see `configurationIssues` for
	/// the sentence version. Nothing else can raise it: a filtered network error is not a dropped
	/// report, it is a report the contract says not to file.
	var droppedReports: Int { get }
}

public extension CrashReporting {
	func recordNonFatal(_ tag: String, _ error: Error) {
		recordNonFatal(tag, error, [:])
	}
}
