//
//  RemoteConfigServicing.swift
//  IntegrationKit
//

import Foundation

/// The app's remote-config surface — Firebase Remote Config behind it, reached as
/// `IntegrationKit.remoteConfig`. The layer is already configured by the time the app holds one:
/// the composition root registers the defaults and starts the fetch.
///
/// Keys and defaults belong to the app, not to the package, so nothing here names one. The app
/// passes its defaults to ``IntegrationKit/configure(deviceId:amplitudeKey:adaptyKey:placements:sessionsCounter:sharedSecret:productIds:isDebug:isTestsRunning:levels:firstOpenEvent:appsFlyerDevKey:appsFlyerAppId:sourceTimeout:attTimeout:adaptyAttributionEnabled:remoteConfigDefaults:remoteConfigTimeout:)``
/// and reads them back by the same key.
///
/// Every read is non-blocking and answers immediately: the registered default until the fetch
/// lands, the fetched value afterwards. A key with no default answers the type's zero — `false`,
/// `""`, `0` — which is the one case worth avoiding, because it is indistinguishable from a
/// fetched value. Register a default for every key the app reads.
public protocol RemoteConfigServicing: AnyObject {
	/// The remote value for `key`, or its registered default while the fetch is still in flight.
	func bool(_ key: String) -> Bool
	/// See ``bool(_:)``.
	func string(_ key: String) -> String
	/// See ``bool(_:)``.
	func int(_ key: String) -> Int
	/// See ``bool(_:)``.
	func double(_ key: String) -> Double
}
