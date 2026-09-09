//
//  CrashReporter.swift
//  IntegrationKit
//

import FirebaseCore
import FirebaseCrashlytics
import Foundation

struct CrashReporter: CrashReporting {

	/// The custom key the tag travels under. Filter the Crashlytics dashboard on it to see one
	/// subsystem's non-fatals: `ik_tag = premium`. Short and prefixed so it cannot collide with a
	/// key the app sets itself.
	static let tagKey = "ik_tag"

	/// CR-02 row 5 says this service is safe because it holds no state. The counter below is the one
	/// exception, so it carries its own lock rather than resting on that claim.
	private static let lock = NSLock()
	private static var dropped = 0

	init() {}

	var droppedReports: Int {
		Self.lock.lock()
		defer { Self.lock.unlock() }
		return Self.dropped
	}

	/// Checks only.
	static func resetDroppedReports() {
		lock.lock()
		dropped = 0
		lock.unlock()
	}

	func recordNonFatal(_ tag: String, _ error: Error, _ info: [String: Any]) {
		let nsError = error as NSError
		let isNoise = nsError.domain == NSURLErrorDomain
			&& (nsError.code == NSURLErrorNotConnectedToInternet || nsError.code == NSURLErrorCancelled)
		guard !isNoise else { return }

		// CR-01 row 1. The worst failure mode for a tool whose only job is not to be silent: an app
		// that forgot `FirebaseIntegration.configure()` hands every report to a Crashlytics that
		// isn't there, and finds out a week after release, from an empty dashboard. Counted rather
		// than lost, and the cause is recorded once — not once per report.
		guard FirebaseApp.app() != nil else {
			Self.lock.lock()
			Self.dropped += 1
			Self.lock.unlock()
			ConfigurationIssues.shared.record(
				"Firebase is not up — crash reports are being dropped; call FirebaseIntegration.configure() before IntegrationKit.configure(...)",
				tag: "Crashlytics"
			)
			return
		}

		// CR-02 row 1: `userInfo` is only visible inside an issue that is already open, and this tag
		// exists to *find* the issue — "everything from premium" is a dashboard filter, and only a
		// custom key can be filtered on.
		Crashlytics.crashlytics().setCustomValue(tag, forKey: Self.tagKey)
		Crashlytics.crashlytics().record(error: error, userInfo: info)
	}
}
