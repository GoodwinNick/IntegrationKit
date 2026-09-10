//
//  RemoteConfigValue.swift
//  IntegrationKit — Checks/Stubs/FirebaseRemoteConfig
//
//  Stand-in for `RemoteConfigValue` (Firebase 12.x). The real one is a box the SDK hands back for
//  ANY key — a key nobody ever set included — and it answers `false`, `""` and `0` for that case
//  rather than nil. That is the whole reason `RemoteConfigServicing` tells callers to register a
//  default for every key they read, so the stub reproduces it exactly.
//
//  KNOWN DIVERGENCE (RC-03 row 4): this stub does not convert between representations, and the real
//  `FIRConfigValue` does — it holds `NSData` and derives the bool, the string and the number from
//  it, so a console value of "true" read through `boolValue` behaves differently there. A green
//  assert about conversion proves nothing until this is closed; RC-03 row 3's assert is written to
//  compare the two branches with each other, not against the SDK.
//

import Foundation

/// `FIRRemoteConfigSource` (`FIRRemoteConfig.h:116-120`). Only `static` carries weight in the
/// package: it is the SDK's way of saying "this key exists nowhere", and the only thing that tells
/// a fetched `false` from a key nobody registered.
public enum RemoteConfigSource: Int {
	case remote
	case `default`
	case `static`
}

public final class RemoteConfigValue {
	private let value: NSObject?
	public let source: RemoteConfigSource

	init(value: NSObject?, source: RemoteConfigSource) {
		self.value = value
		self.source = source
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
