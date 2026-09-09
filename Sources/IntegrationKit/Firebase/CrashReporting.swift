//
//  CrashReporting.swift
//  IntegrationKit
//

import Foundation

/// The app's channel for non-fatal reports, reached as `IntegrationKit.crashes`. Crashlytics behind
/// it only exists once `FirebaseIntegration.configure(isDebug:)` has run.
public protocol CrashReporting {
	/// Files `error` with Crashlytics as a non-fatal: `info` becomes the report's `userInfo`, and
	/// `tag` is set as the custom key `ik_tag`, which is what the dashboard can be filtered on to
	/// see one subsystem's reports (`ik_tag = premium`).
	///
	/// Two kinds of report never reach Crashlytics. A cancelled request and a "not connected to the
	/// internet" `NSURLError` are dropped as noise — they say nothing about the app. Everything
	/// filed before Firebase was brought up is dropped too, and raises `droppedReports`.
	func recordNonFatal(_ tag: String, _ error: Error, _ info: [String: Any])

	/// Reports that never reached Crashlytics because Firebase was never brought up. Anything but
	/// zero means `FirebaseIntegration.configure()` was not called — see `configurationIssues` for
	/// the sentence version. Nothing else can raise it: a filtered network error is not a dropped
	/// report, it is a report the contract says not to file.
	var droppedReports: Int { get }
}

public extension CrashReporting {
	/// Files a report with no extra `userInfo` — the common case.
	func recordNonFatal(_ tag: String, _ error: Error) {
		recordNonFatal(tag, error, [:])
	}
}
