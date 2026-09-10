//
//  RemoteConfigService.swift
//  IntegrationKit
//

import FirebaseCore
import FirebaseRemoteConfig
import Foundation

final class RemoteConfigService: RemoteConfigServicing {

	private static let tag = "RemoteConfig"

	/// Stands in for a `remoteConfigTimeout` the app cannot have meant — see the guard in
	/// ``configure(timeout:isDebug:isTestsRunning:)``. The same five seconds
	/// `IntegrationKit.configure` uses when the app passes nothing.
	private static let fallbackTimeout: TimeInterval = 5

	/// `FIRRemoteConfigErrorDomain` and `FIRRemoteConfigErrorThrottled`, spelled out rather than
	/// imported: the SDK exposes them to Swift only through a typed `NS_ERROR_ENUM`, and matching a
	/// wrapped `NSError` means comparing the domain string anyway
	/// (`FIRRemoteConfig.h:64-72`, raised at `RCNConfigFetch.m:478-483`).
	private static let errorDomain = "com.google.remoteconfig.ErrorDomain"
	private static let throttledCode = 8002

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

		// RC-01 row 6: a timeout of zero or less is not a shorter fetch, it is a value the SDK was
		// never meant to get. Substituted rather than passed on, because the alternative — letting it
		// through and hoping — differs from a working layer only in that the fetch never lands, and
		// nothing anywhere would say why. Five seconds is the same number `IntegrationKit.configure`
		// hands over when the app says nothing at all.
		var fetchTimeout = timeout
		if fetchTimeout <= 0 {
			ConfigurationIssues.shared.record(
				"Remote config got a fetch timeout of \(timeout) — using \(Self.fallbackTimeout)s instead; pass a positive remoteConfigTimeout",
				tag: Self.tag
			)
			fetchTimeout = Self.fallbackTimeout
		}

		let config = RemoteConfig.remoteConfig()
		let settings = RemoteConfigSettings()
		settings.fetchTimeout = fetchTimeout
		if isDebug {
			settings.minimumFetchInterval = 0
		}
		config.configSettings = settings
		config.setDefaults(defaults)
		remoteConfig = config

		// RC-01 row 3. The count is the point, not the fact: a key missing from the app's dictionary
		// is invisible at runtime — it reads as the type's zero — and this is the one line where the
		// number can be compared against what the console holds before anyone ships.
		debugLog(
			tag: Self.tag,
			"\(defaults.count) default(s) registered, timeout \(fetchTimeout)s, throttle "
				+ (isDebug ? "off (debug)" : "left at the SDK's 12h")
		)

		guard !isTestsRunning else {
			debugLog(tag: Self.tag, "test run: defaults registered, fetch skipped")
			return
		}

		config.fetchAndActivate { status, error in
			if let error {
				let nsError = error as NSError
				// RC-02 row 3: being throttled is the SDK working, not failing — the backoff after a
				// 429 or a 5xx is its own design (`RCNConfigSettings.m:178-202`), and the values in
				// hand stay valid throughout. Filing it would put a normal mode into the tool kept
				// for anomalies, on a schedule nobody controls.
				let isThrottled = nsError.domain == Self.errorDomain && nsError.code == Self.throttledCode
				if !isThrottled {
					// Transient by nature — a fetch fails on a bad network and succeeds on the next
					// launch — so it is a non-fatal and a log line, not a `configurationIssues` entry:
					// that list is for causes no retry will fix. The offline half of this is filtered
					// by `CrashReporter` itself, which unwraps `NSUnderlyingErrorKey` to find it.
					CrashReporter().recordNonFatal(Self.tag, error)
				}
				// RC-02 row 1: the domain and the code, not just the sentence. `localizedDescription`
				// reads the same for a throttle, a timeout and a malformed response, and those are
				// three different things to do next.
				debugLog(
					tag: Self.tag,
					level: .error,
					"fetch failed: \(nsError.domain) \(nsError.code) — \(nsError.localizedDescription)"
				)
				return
			}
			// RC-02 row 4: the raw value said nothing — and naming the status alone would still say
			// less than it looks like. `fetchAndActivate` reports `successFetchedFromRemote` for a
			// pure cache hit as well, where the throttle window had not elapsed and no request was
			// made at all (`FIRRemoteConfig.m:382-383`), so the line says what it cannot tell apart
			// rather than letting the reader assume the console answered.
			debugLog(
				tag: Self.tag,
				"fetch finished: \(Self.describe(status)) (does not distinguish a fresh answer from a cached one)"
			)
		}
	}

	private static func describe(_ status: RemoteConfigFetchAndActivateStatus) -> String {
		switch status {
			case .successFetchedFromRemote: return "success, fetched from remote"
			case .successUsingPreFetchedData: return "success, using pre-fetched data"
			case .error: return "error"
			@unknown default: return "unknown status \(status.rawValue)"
		}
	}

	func bool(_ key: String) -> Bool {
		guard let remoteConfig else { return (fallback(key) as? NSNumber)?.boolValue ?? false }
		return read(key, from: remoteConfig).boolValue
	}

	func string(_ key: String) -> String {
		guard let remoteConfig else { return fallback(key) as? String ?? "" }
		return read(key, from: remoteConfig).stringValue
	}

	func int(_ key: String) -> Int {
		guard let remoteConfig else { return (fallback(key) as? NSNumber)?.intValue ?? 0 }
		return read(key, from: remoteConfig).numberValue.intValue
	}

	func double(_ key: String) -> Double {
		guard let remoteConfig else { return (fallback(key) as? NSNumber)?.doubleValue ?? 0 }
		return read(key, from: remoteConfig).numberValue.doubleValue
	}

	/// The defaulted branch's half of RC-03 row 1 — no SDK to ask, so a key the app never registered
	/// is simply missing from the dictionary.
	private func fallback(_ key: String) -> NSObject? {
		guard let value = defaults[key] else {
			warnMissing(key)
			return nil
		}
		return value
	}

	/// The active branch's half. `source` is the only thing that separates "the console sent false"
	/// from "nobody ever heard of this key": the SDK hands back a value object either way, filled
	/// with the type's zero for the second (`FIRRemoteConfig.m:503-507`).
	private func read(_ key: String, from config: RemoteConfig) -> RemoteConfigValue {
		let value = config.configValue(forKey: key)
		if value.source == .static {
			warnMissing(key)
		}
		return value
	}

	/// RC-03 row 1. Deliberately not deduplicated and deliberately not a `configurationIssues` entry.
	///
	/// Not deduplicated because remembering which keys have been warned about would give this layer
	/// mutable state that outlives `configure`, and a lock to go with it — and the whole reason reads
	/// are safe from any queue (RC-03 row 5) is that there is none. A key read once per cell will
	/// flood the debug console, and that is the signal doing its job: nothing here reaches a shipping
	/// build, where `debugLog` prints nothing at all.
	///
	/// Not a `configurationIssues` entry because that list is written during configuration, and this
	/// is a read: an entry appearing there depending on which screen the user opened would make the
	/// list itself unreliable.
	private func warnMissing(_ key: String) {
		debugLog(
			tag: Self.tag,
			level: .error,
			"no default registered for \"\(key)\" — the read answers the type's zero, which is "
				+ "indistinguishable from a value the console really sent"
		)
	}
}
