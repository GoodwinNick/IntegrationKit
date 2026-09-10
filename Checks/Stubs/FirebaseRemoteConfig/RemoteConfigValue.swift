//
//  RemoteConfigValue.swift
//  IntegrationKit — Checks/Stubs/FirebaseRemoteConfig
//
//  Stand-in for `RemoteConfigValue` (Firebase 12.x). The real one is a box the SDK hands back for
//  ANY key — a key nobody ever set included — and it answers `false`, `""` and `0` for that case
//  rather than nil. That is the whole reason `RemoteConfigServicing` tells callers to register a
//  default for every key they read, so the stub reproduces it exactly.
//

import Foundation

public final class RemoteConfigValue {
	private let value: NSObject?

	init(value: NSObject?) {
		self.value = value
	}

	public var boolValue: Bool {
		(value as? NSNumber)?.boolValue ?? false
	}

	public var stringValue: String {
		value as? String ?? ""
	}

	public var numberValue: NSNumber {
		(value as? NSNumber) ?? NSNumber(value: 0)
	}
}
