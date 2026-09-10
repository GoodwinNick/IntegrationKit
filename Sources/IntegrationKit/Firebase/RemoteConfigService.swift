//
//  RemoteConfigService.swift
//  IntegrationKit
//

import FirebaseCore
import FirebaseRemoteConfig
import Foundation

final class RemoteConfigService: RemoteConfigServicing {

	private static let tag = "RemoteConfig"

	/// Kept as well as handed to Firebase: they are the answer whenever `remoteConfig` is nil, which
	/// is the case an app hits by forgetting `FirebaseIntegration.configure()`. Answering the type's
	/// zero there would look exactly like a fetched `false`.
	private let defaults: [String: NSObject]
	private var remoteConfig: RemoteConfig?

	init(defaults: [String: NSObject]) {
		self.defaults = defaults
	}

	/// Registers the defaults and starts the fetch. Non-blocking — callers read straight away and
	/// get the default until the fetch lands.
	///
	/// `isDebug` is the app's own `#if DEBUG`, the same flag the rest of the package runs off, and
	/// here it turns the fetch throttle off: Firebase allows one fetch per 12 hours by default,
	/// which makes flipping a flag in the console during manual testing look broken. The package
	/// cannot read `#if DEBUG` itself — one compiled into a library cannot be turned off by the app
	/// that embeds it, the same argument `FirebaseIntegration.configure(isDebug:)` makes.
	///
	/// `isTestsRunning` keeps the defaults and skips the fetch: a UI test asserting on a paywall
	/// variant must not have the console decide which one it gets. Unlike the other three SDKs the
	/// layer stays usable — it answers the app's own defaults, which is what a test wants.
	func configure(timeout: TimeInterval, isDebug: Bool, isTestsRunning: Bool) {
		// The same guard as `CrashReporter`, for the same reason: `RemoteConfig.remoteConfig()`
		// needs a configured `FirebaseApp` and takes the app down with an exception without one.
		guard FirebaseApp.app() != nil else {
			ConfigurationIssues.shared.record(
				"Firebase is not up — remote config answers its defaults for this run; call FirebaseIntegration.configure() before IntegrationKit.configure(...)",
				tag: Self.tag
			)
			return
		}
		guard !defaults.isEmpty else {
			// Not a fetch worth making: with no defaults registered every read answers the type's
			// zero until the fetch lands, and no caller can tell that apart from a real value.
			ConfigurationIssues.shared.record(
				"Remote config got no defaults — every key reads as false/\"\"/0 until the fetch lands",
				tag: Self.tag
			)
			return
		}

		let config = RemoteConfig.remoteConfig()
		let settings = RemoteConfigSettings()
		settings.fetchTimeout = timeout
		if isDebug {
			settings.minimumFetchInterval = 0
		}
		config.configSettings = settings
		config.setDefaults(defaults)
		remoteConfig = config

		guard !isTestsRunning else {
			debugLog(tag: Self.tag, "test run: defaults registered, fetch skipped")
			return
		}

		config.fetchAndActivate { status, error in
			if let error {
				// Transient by nature — a fetch fails on a bad network and succeeds on the next
				// launch — so it is a non-fatal and a log line, not a `configurationIssues` entry:
				// that list is for causes no retry will fix.
				CrashReporter().recordNonFatal(Self.tag, error)
				debugLog(tag: Self.tag, level: .error, "fetch failed: \(error.localizedDescription)")
				return
			}
			debugLog(tag: Self.tag, "fetch finished with status \(status.rawValue)")
		}
	}

	func bool(_ key: String) -> Bool {
		guard let remoteConfig else { return (defaults[key] as? NSNumber)?.boolValue ?? false }
		return remoteConfig.configValue(forKey: key).boolValue
	}

	func string(_ key: String) -> String {
		guard let remoteConfig else { return defaults[key] as? String ?? "" }
		return remoteConfig.configValue(forKey: key).stringValue
	}

	func int(_ key: String) -> Int {
		guard let remoteConfig else { return (defaults[key] as? NSNumber)?.intValue ?? 0 }
		return remoteConfig.configValue(forKey: key).numberValue.intValue
	}

	func double(_ key: String) -> Double {
		guard let remoteConfig else { return (defaults[key] as? NSNumber)?.doubleValue ?? 0 }
		return remoteConfig.configValue(forKey: key).numberValue.doubleValue
	}
}
