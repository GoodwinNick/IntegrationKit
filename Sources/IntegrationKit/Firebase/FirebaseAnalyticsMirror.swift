//
//  FirebaseAnalyticsMirror.swift
//  IntegrationKit
//

import FirebaseAnalytics
import FirebaseCore
import Foundation

/// The one place the package talks to Firebase Analytics (FA-01…FA-05). Everything the app sends to
/// Amplitude — events, user properties, the user id — is handed here as well, by `AmplitudeAnalytics`,
/// in the same call; a purchase and the Firebase instance id arrive from `AdaptyService`,
/// `StoreKitService` and the composition root. Nothing else in `Sources/` calls Firebase Analytics;
/// the two purchase paths only name `Analytics.logTransaction` to hand it over (see `logTransaction`).
///
/// What the layer does NOT do, on purpose: rename. Amplitude keeps its own names (the app's
/// dashboards are built on them), and Firebase gets the same names or nothing — a name or key it
/// would drop is not sent and is named in an `error` line instead (FA-02 r5…r8, decision 2026-10-01).
/// A drop inside Firebase comes back as a noise `error` event in the dashboard; one in here is a
/// line in the console the developer is already reading.
///
/// Stateless apart from the last instance id handed to Adapty, so it can be called from any thread.
final class FirebaseAnalyticsMirror {
	private static let tag = "FirebaseAnalytics"

	/// `FIRAnalytics.h:23-56` (12.19.2) — "events with these names will be dropped, and instead an error
	/// event will be logged". `screen_view` and `in_app_purchase` are NOT on it.
	private static let reservedEventNames: Set<String> = [
		"ad_activeview", "ad_click", "ad_exposure", "ad_query", "ad_reward", "adunit_exposure",
		"app_clear_data", "app_exception", "app_remove", "app_store_refund", "app_store_subscription_cancel",
		"app_store_subscription_convert", "app_store_subscription_renew", "app_update", "app_upgrade",
		"dynamic_link_app_open", "dynamic_link_app_update", "dynamic_link_first_open", "error",
		"firebase_campaign", "first_open", "first_visit", "notification_dismiss", "notification_foreground",
		"notification_open", "notification_receive", "os_update", "session_start", "session_start_with_rollout",
		"user_engagement",
	]
	/// `FIRAnalytics.h:78-83`.
	private static let reservedPropertyNames: Set<String> = ["first_open_time", "last_deep_link_referrer", "user_id"]
	private static let reservedPrefixes = ["firebase_", "google_", "ga_"]

	/// `FIRAnalytics.h:19-70`, `:85-98`. Strings count in UTF-16 code units, which is what `NSString`
	/// counts and what Firebase measures — "100 characters" is 100 of those, not 100 graphemes.
	private static let maxEventNameLength = 40
	private static let maxParameterKeyLength = 40
	private static let maxParameterCount = 25
	private static let maxParameterValueLength = 100
	private static let maxPropertyNameLength = 24
	private static let maxPropertyValueLength = 36
	private static let maxUserIdLength = 256

	private let lock = NSLock()
	private var lastDeliveredInstanceId: String?

	/// "Is Firebase up" is asked of the SDK on every call and never remembered: an app that brings
	/// Firebase up late is still heard from that moment on. The cause lands in `configurationIssues`
	/// once — `ConfigurationIssues` drops a repeated text — because a call that fails on every
	/// invocation must leave one line, not one per event.
	private var isUp: Bool {
		guard FirebaseApp.app() != nil else {
			ConfigurationIssues.shared.record(
				"Firebase is not up — call FirebaseIntegration.configure() before IntegrationKit.configure, otherwise no event, user property or purchase reaches Firebase Analytics",
				tag: Self.tag
			)
			return false
		}
		return true
	}

	/// FA-01. The collection flag is stored by the SDK between launches, so it is written on EVERY
	/// launch in both directions — a test run that only ever switched it off would leave the device
	/// off for every build installed after it. A debug build collects like a release one: without it
	/// there is no DebugView, and the `environment` property tells the two apart.
	///
	/// A test run with Firebase down is not a complaint: the app's test build is allowed to skip it.
	func configure(isTestsRunning: Bool) {
		guard FirebaseApp.app() != nil else {
			if !isTestsRunning {
				_ = isUp
			}
			return
		}
		Analytics.setAnalyticsCollectionEnabled(!isTestsRunning)
		debugLog(tag: Self.tag, isTestsRunning ? "collection disabled — the app reported a test run" : "collection enabled")
	}

	func logEvent(_ event: String, properties: [String: Any]?) {
		guard isUp else { return }
		if let problem = Self.nameProblem(event, maxLength: Self.maxEventNameLength) ?? Self.reservedProblem(event, in: Self.reservedEventNames) {
			debugLog(tag: Self.tag, level: .error, "event \"\(event)\" is not sent to Firebase — \(problem)")
			return
		}
		let parameters = sanitizedParameters(properties ?? [:], event: event)
		if parameters.count > Self.maxParameterCount {
			// Which ones Firebase drops is not documented, and choosing for it is not this layer's job.
			debugLog(tag: Self.tag, level: .error, "event \"\(event)\" carries \(parameters.count) parameters and Firebase takes \(Self.maxParameterCount) — it decides itself which are dropped")
		}
		debugLog(tag: Self.tag, "LOG EVENT \(event).   Properties: \(String(describing: parameters))")
		Analytics.logEvent(event, parameters: parameters.isEmpty ? nil : parameters)
	}

	func setUserProperties(_ properties: [String: Any]) {
		guard isUp else { return }
		for (key, value) in properties {
			if let problem = Self.nameProblem(key, maxLength: Self.maxPropertyNameLength) ?? Self.reservedProblem(key, in: Self.reservedPropertyNames) {
				debugLog(tag: Self.tag, level: .error, "user property \"\(key)\" is not sent to Firebase — \(problem)")
				continue
			}
			// `nil` removes the property in Firebase, which is what `NSNull` means on the Amplitude side.
			let text = Self.text(of: value)
			debugLog(tag: Self.tag, "UserProperty: \(key) | value: \(text ?? "removed")")
			Analytics.setUserProperty(text.map { Self.cut($0, to: Self.maxPropertyValueLength, what: "user property \"\(key)\"") }, forName: key)
		}
	}

	/// An empty id would join every profile to nobody, and a cut one would join different users into
	/// one — so neither is sent.
	func setUserId(_ userId: String) {
		guard isUp else { return }
		guard !userId.isEmpty, userId.utf16.count <= Self.maxUserIdLength else {
			debugLog(tag: Self.tag, level: .error, "user id is not sent to Firebase — it must be 1…\(Self.maxUserIdLength) characters (got \(userId.utf16.count))")
			return
		}
		debugLog(tag: Self.tag, "UserId: \(userId)")
		Analytics.setUserID(userId)
	}

	/// FA-04. Generic over the transaction and handed the SDK's function, because `StoreKit.Transaction`
	/// has no public initialiser — a check cannot build one, and could never reach this line with a
	/// parameter of that type. The callers pass `Analytics.logTransaction`, so the real call is
	/// exactly the one Firebase documents; only a VERIFIED transaction may arrive here.
	func logTransaction<T>(_ transaction: T, send: (T) -> Void) {
		guard isUp else { return }
		debugLog(tag: Self.tag, "LOG TRANSACTION \(transaction)")
		send(transaction)
	}

	/// FA-05. Reads the id and hands it over when it is new. `nil` is a legal answer (analytics
	/// storage denied by consent, or not ready yet) and is a log line, not a configuration issue; an
	/// empty string joins nothing and is treated as `nil`. The same id is delivered once per process,
	/// a changed one (the app reset Firebase's data) follows.
	func syncAppInstanceId(deliver: (String) -> Void) {
		guard isUp else { return }
		let id = Analytics.appInstanceID()
		debugLog(tag: Self.tag, "AppInstanceId: \(id ?? "nil")")
		guard let id, !id.isEmpty else { return }
		lock.lock()
		let isNew = lastDeliveredInstanceId != id
		lastDeliveredInstanceId = id
		lock.unlock()
		if isNew {
			deliver(id)
		}
	}

	// MARK: - Sanitiser

	private func sanitizedParameters(_ properties: [String: Any], event: String) -> [String: Any] {
		var result: [String: Any] = [:]
		for (key, value) in properties {
			if let problem = Self.nameProblem(key, maxLength: Self.maxParameterKeyLength) {
				debugLog(tag: Self.tag, level: .error, "parameter \"\(key)\" of event \"\(event)\" is not sent to Firebase — \(problem)")
				continue
			}
			guard let converted = Self.parameterValue(value) else {
				debugLog(tag: Self.tag, level: .error, "parameter \"\(key)\" of event \"\(event)\" is not sent to Firebase — NSNull has no form there")
				continue
			}
			if let string = converted as? String {
				result[key] = Self.cut(string, to: Self.maxParameterValueLength, what: "parameter \"\(key)\" of event \"\(event)\"")
			} else {
				result[key] = converted
			}
		}
		return result
	}

	/// Firebase takes String, Int and Double and nothing else. `NSNumber` is told apart by its Core
	/// Foundation type, not by `as? Bool` — Swift bridges `NSNumber(1)` to `true`, which would turn a
	/// number into text. `nil` means "no Firebase form": only `NSNull`.
	private static func parameterValue(_ value: Any) -> Any? {
		if value is NSNull { return nil }
		if let number = value as? NSNumber {
			if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue ? "true" : "false" }
			if CFNumberIsFloatType(number as CFNumber) { return number.doubleValue }
			return number.intValue
		}
		if let string = value as? String { return string }
		return String(describing: value)
	}

	/// The same for a user property, where the only form is text.
	private static func text(of value: Any) -> String? {
		guard let converted = parameterValue(value) else { return nil }
		return String(describing: converted)
	}

	/// Cuts to `limit` UTF-16 code units without splitting a character — an emoji that would cross the
	/// limit goes whole, never as half a surrogate pair. Firebase drops the entire parameter for a
	/// string over the limit, so cutting is the lesser loss; the cut is logged with both lengths.
	private static func cut(_ text: String, to limit: Int, what: String) -> String {
		let length = text.utf16.count
		guard length > limit else { return text }
		var units = 0
		var result = ""
		for character in text {
			units += character.utf16.count
			if units > limit { break }
			result.append(character)
		}
		debugLog(tag: tag, "\(what): value cut from \(length) to \(result.utf16.count) characters for Firebase")
		return result
	}

	/// `nil` when Firebase takes the name. 1…`maxLength` characters of letters, digits and `_`, the
	/// first a letter, none of the three reserved prefixes (case-sensitive, like Firebase's names).
	private static func nameProblem(_ name: String, maxLength: Int) -> String? {
		guard !name.isEmpty else { return "the name is empty" }
		guard name.utf8.count <= maxLength else { return "the name is \(name.utf8.count) characters and Firebase takes \(maxLength) at most" }
		guard let first = name.utf8.first, isLetter(first) else { return "the name must start with a letter" }
		guard name.utf8.allSatisfy({ isLetter($0) || isDigit($0) || $0 == UInt8(ascii: "_") }) else {
			return "the name may hold only letters, digits and underscores"
		}
		if let prefix = reservedPrefixes.first(where: { name.hasPrefix($0) }) {
			return "the prefix \"\(prefix)\" is reserved"
		}
		return nil
	}

	private static func reservedProblem(_ name: String, in reserved: Set<String>) -> String? {
		reserved.contains(name) ? "the name is reserved by Firebase" : nil
	}

	private static func isLetter(_ byte: UInt8) -> Bool {
		(UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte) || (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte)
	}

	private static func isDigit(_ byte: UInt8) -> Bool {
		(UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
	}
}
