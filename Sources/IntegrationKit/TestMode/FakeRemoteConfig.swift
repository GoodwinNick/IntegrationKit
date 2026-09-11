//
//  FakeRemoteConfig.swift
//  IntegrationKit
//
//  The Firebase half of TM-06. A key the test did not set answers the default the app registered at
//  launch — not "unknown" — because that is exactly what a live Firebase answers before its first
//  fetch lands (TM-06 row 4). No fetch is made and no network is touched (TM-06 row 6).
//

import Foundation

final class FakeRemoteConfig: RemoteConfigServicing {

	/// `-remoteConfig key=value`, already typed by TM-02. A separate space from the paywall's own
	/// values: the same key in both flags is two unrelated values, on purpose (TM-06 row 1).
	private let values: [String: Any]
	private let defaults: [String: NSObject]

	init(values: [String: Any], defaults: [String: NSObject]) {
		self.values = values
		self.defaults = defaults
	}

	// Conversions are permissive in the same way Firebase's own `RemoteConfigValue` is: a value that
	// arrived as `3` reads as `3`, `3.0` or `"3"` depending on who asks. The parse order that
	// produced it is what matters — `Int` strictly before `Double`, TM-02 row 3.

	func bool(_ key: String) -> Bool {
		guard let raw = values[key] else { return (defaults[key] as? NSNumber)?.boolValue ?? false }
		if let value = raw as? Bool { return value }
		if let value = raw as? Int { return value != 0 }
		if let value = raw as? Double { return value != 0 }
		if let value = raw as? String { return (value as NSString).boolValue }
		return false
	}

	func string(_ key: String) -> String {
		guard let raw = values[key] else { return defaults[key] as? String ?? "" }
		if let value = raw as? String { return value }
		return String(describing: raw)
	}

	func int(_ key: String) -> Int {
		guard let raw = values[key] else { return (defaults[key] as? NSNumber)?.intValue ?? 0 }
		if let value = raw as? Int { return value }
		if let value = raw as? Bool { return value ? 1 : 0 }
		if let value = raw as? Double { return Int(value) }
		if let value = raw as? String { return Int(value) ?? 0 }
		return 0
	}

	func double(_ key: String) -> Double {
		guard let raw = values[key] else { return (defaults[key] as? NSNumber)?.doubleValue ?? 0 }
		if let value = raw as? Double { return value }
		if let value = raw as? Int { return Double(value) }
		if let value = raw as? Bool { return value ? 1 : 0 }
		if let value = raw as? String { return Double(value) ?? 0 }
		return 0
	}
}
