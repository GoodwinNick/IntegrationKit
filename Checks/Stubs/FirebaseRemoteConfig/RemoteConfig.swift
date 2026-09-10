//
//  RemoteConfig.swift
//  IntegrationKit — Checks/Stubs/FirebaseRemoteConfig
//
//  Stand-in for `RemoteConfig` (Firebase 12.x). A shared singleton like the real one, so a check
//  drives it through the static controls below and reads back what the service did:
//
//  - `fetched` is what the console "sent"; set it before `fetchAndActivate` lands and the values
//    read afterwards come from there instead of the defaults.
//  - `fetchError` makes the fetch fail, which is the non-fatal path.
//  - `fetchCallCount` tells a skipped fetch (a test run) from one that was made and failed.
//  - `appliedSettings` and `registeredDefaults` are what the service handed over, so the throttle
//    and the defaults can be asserted rather than assumed.
//
//  `fetchAndActivate` answers SYNCHRONOUSLY, unlike the real one. The service does nothing after
//  the completion but log, and a check that had to wait for a real queue hop would be timing-
//  dependent for no gain.
//

import Foundation

public final class RemoteConfig {

	private static let shared = RemoteConfig()

	/// What the console "sent". Empty means the fetch changed nothing.
	public static var fetched: [String: NSObject] = [:]
	/// Non-nil makes `fetchAndActivate` fail with it.
	public static var fetchError: Error?
	public static var fetchStatus: RemoteConfigFetchAndActivateStatus = .successFetchedFromRemote
	public private(set) static var fetchCallCount = 0
	public private(set) static var appliedSettings: RemoteConfigSettings?
	public private(set) static var registeredDefaults: [String: NSObject] = [:]

	private init() {}

	public static func reset() {
		fetched = [:]
		fetchError = nil
		fetchStatus = .successFetchedFromRemote
		fetchCallCount = 0
		appliedSettings = nil
		registeredDefaults = [:]
	}

	public static func remoteConfig() -> RemoteConfig {
		shared
	}

	public var configSettings: RemoteConfigSettings {
		get { Self.appliedSettings ?? RemoteConfigSettings() }
		set { Self.appliedSettings = newValue }
	}

	public func setDefaults(_ defaults: [String: NSObject]?) {
		Self.registeredDefaults = defaults ?? [:]
	}

	public func fetchAndActivate(completionHandler: ((RemoteConfigFetchAndActivateStatus, Error?) -> Void)? = nil) {
		Self.fetchCallCount += 1
		if let error = Self.fetchError {
			completionHandler?(.error, error)
			return
		}
		completionHandler?(Self.fetchStatus, nil)
	}

	/// The fetched value if the console sent one, otherwise the registered default — the real SDK's
	/// own precedence, and the reason a read never has a "not ready" state to handle. The third case
	/// is the one RC-03 row 1 turns on: a key in neither place still gets a value object, and only
	/// `source` says so.
	public func configValue(forKey key: String) -> RemoteConfigValue {
		if let fetched = Self.fetched[key] {
			return RemoteConfigValue(value: fetched, source: .remote)
		}
		if let registered = Self.registeredDefaults[key] {
			return RemoteConfigValue(value: registered, source: .default)
		}
		return RemoteConfigValue(value: nil, source: .static)
	}
}
