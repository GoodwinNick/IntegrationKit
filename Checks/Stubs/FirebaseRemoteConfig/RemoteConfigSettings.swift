//
//  RemoteConfigSettings.swift
//  IntegrationKit — Checks/Stubs/FirebaseRemoteConfig
//
//  Stand-in for `RemoteConfigSettings` (Firebase 12.x). A class, like the real one, because the
//  service builds one, mutates it and hands it over — a struct would make the assignment a copy and
//  hide whether the settings ever reached the config object.
//
//  The real default for `minimumFetchInterval` is 12 hours; it is spelled out so a check can assert
//  the debug build actually cleared it rather than assert against zero either way.
//

import Foundation

public final class RemoteConfigSettings {
	public var fetchTimeout: TimeInterval = 60
	public var minimumFetchInterval: TimeInterval = 12 * 60 * 60

	public init() {}
}
