//
//  RemoteValue.swift
//  IntegrationKit
//

import Foundation

/// One read of a paywall's remote config — AD-07 row 1. Four different causes used to collapse into
/// one `nil`, so a screen that reads a flag could not tell "ask again in a second" from "the
/// dashboard never set this" from "the dashboard set it to the wrong type". An A/B test that
/// silently degrades to its default for part of the audience still looks like a working test.
public enum RemoteValue<Value>: Sendable where Value: Sendable {
	/// The value is there and is of the requested type.
	case value(Value)
	/// The placement's paywall has not arrived yet — the same read later can succeed.
	case notReady
	/// The paywall is loaded and carries no remote config at all.
	case noConfig
	/// The config is there and does not contain this key.
	case notSet
	/// The key is there and holds another type than the caller asked for. A dashboard mistake —
	/// it is also recorded in `IntegrationKit.configurationIssues`.
	case wrongType

	/// The plain answer, for a caller that only wants "the value or my own default".
	public var value: Value? {
		guard case let .value(value) = self else { return nil }
		return value
	}

	/// `true` while asking again can still change the answer.
	public var isPending: Bool {
		if case .notReady = self { return true }
		return false
	}
}
