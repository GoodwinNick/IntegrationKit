//
//  RemoteConfigFetchAndActivateStatus.swift
//  IntegrationKit — Checks/Stubs/FirebaseRemoteConfig
//
//  Stand-in for the real enum (Firebase 12.x). Only the raw value matters here: the service logs it
//  and decides nothing on it — every outcome that is not an error leaves the values readable.
//

import Foundation

public enum RemoteConfigFetchAndActivateStatus: Int {
	case successFetchedFromRemote = 0
	case successUsingPreFetchedData = 1
	case error = 2
}
