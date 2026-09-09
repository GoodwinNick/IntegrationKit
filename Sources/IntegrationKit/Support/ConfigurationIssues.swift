//
//  ConfigurationIssues.swift
//  IntegrationKit
//
//  Where "this cannot work, and no retry will fix it" goes. Every service in the package has
//  failures that a user never sees and a DEBUG log outlives by one launch: an empty key, a device
//  id that arrived too late, a value an SDK refuses, an attribution write that landed before the
//  SDK was up. The schemas all end at the same requirement — the cause must survive somewhere the
//  app can read it, and must land ONCE per cause, not once per call.
//

import Foundation

/// Configuration problems collected across the whole package, in the order they were first seen.
///
/// Deliberately not an error type: nothing here is thrown or handled. It is a list the app can
/// print, ship to Crashlytics, or assert on in a test — the observable half of every "fails
/// silently" row in the schemas.
///
/// Internal on purpose: the app reads the same list as a plain `[String]` through
/// `IntegrationKit.configurationIssues` or `PremiumServicing.configurationIssues`. Handing out the
/// collector itself would let the app `record` into the very list an integrator reads as the
/// package's own verdict.
final class ConfigurationIssues {

	static let shared = ConfigurationIssues()

	private let lock = NSLock()
	private var seen: Set<String> = []
	private var ordered: [String] = []

	init() {}

	/// Everything recorded so far, oldest first.
	var all: [String] {
		lock.lock()
		defer { lock.unlock() }
		return ordered
	}

	/// Records one problem. A repeat of the same text is dropped, so a call that fails on every
	/// invocation leaves one line rather than one per call.
	///
	/// Returns `true` when the text was new — the callers that also want a log line use that to
	/// avoid printing the same sentence a thousand times.
	@discardableResult
	func record(_ text: String, tag: String? = nil) -> Bool {
		lock.lock()
		let isNew = seen.insert(text).inserted
		if isNew {
			ordered.append(text)
		}
		lock.unlock()
		if isNew {
			debugLog(tag: tag, level: .error, text)
		}
		return isNew
	}

	/// Only the checks call this — a row must not inherit the previous row's issues.
	func reset() {
		lock.lock()
		seen.removeAll()
		ordered.removeAll()
		lock.unlock()
	}
}
