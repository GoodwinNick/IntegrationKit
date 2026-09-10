//
//  AmplitudeAnalytics.swift
//  IntegrationKit
//

import AmplitudeSwift
import AppTrackingTransparency
import Foundation

final class AmplitudeAnalytics: AnalyticsTracking {

	private static let tag = "AmplitudeAnalytics"
	private static let firstOpenTrackedKey = "IntegrationKit.amplitude.firstOpenTracked"

	private var amplitude: Amplitude?
	/// AN-04 row 1. The SDK looks like it would dedupe this for us — `Timeline.add(plugin:)` skips a
	/// plugin whose `name` is already registered — but `name` is only a default implementation on
	/// the `Plugin` protocol extension (`Types.swift:133-137`), and `EnrichmentPlugin` conforms
	/// without declaring it. The witness is therefore fixed to `nil` at the conformance, and a
	/// `name` on our subclass would never be the one `Timeline` reads. One flag on our side is what
	/// actually works on this pin.
	private var didAddIDFAPlugin = false

	/// The app's own `#if DEBUG`, the same value the composition root hands every other SDK. Taken
	/// at build time rather than at `configure`, because it cannot change for the life of the
	/// object — and taken from the app, because a package's own `#if DEBUG` answers about the
	/// package's build, not the app's. Defaults only so the checks' own call sites stay short.
	private let isDebug: Bool

	init(isDebug: Bool = false) {
		self.isDebug = isDebug
	}

	/// Brings the layer up. Deliberately absent from `AnalyticsTracking`: only the composition root
	/// calls it, and a second call would stand up a second Amplitude instance and re-enter the
	/// first-open gate.
	///
	/// `firstOpenEvent` is logged once per install, under the package's own gate. `isTestsRunning`
	/// is the app's own answer to "is this a test run" — the layer does not start at all when it is
	/// true, and the gate above is left unspent (AN-01 rows 3 and 8). It defaults only so the
	/// checks' own call sites stay short — the composition root always passes the app's answer, and
	/// the app always computes it.
	func configure(apiKey: String, deviceId: String, firstOpenEvent: String? = nil, isTestsRunning: Bool = false) {
		// AN-01 rows 3 and 8: the second of the two ways this layer is legally off. Ahead of every
		// other line on purpose — the first-open gate below writes `UserDefaults`, and a test run
		// that spent it would take this device out of the install funnel for good. The reason is
		// its own: an app without analytics and a test run are different facts with one state.
		guard !isTestsRunning else {
			ConfigurationIssues.shared.record(
				"Amplitude is off for this run — the app reported a test run",
				tag: Self.tag
			)
			return
		}
		// AN-01 row 3: an empty key is a supported way to switch analytics off, but a silent one is
		// indistinguishable from a broken integration a week later, when the dashboard is empty and
		// nobody remembers which build this was.
		guard !apiKey.isEmpty else {
			ConfigurationIssues.shared.record(
				"Amplitude got an empty API key — no events are sent for this run",
				tag: Self.tag
			)
			return
		}
		amplitude = Amplitude(configuration: Configuration(apiKey: apiKey))
		// User id goes in before the first event, so even the first event carries it.
		setUserId(deviceId)
		// AN-01 row 11: on every launch, and re-read on every launch. This used to live inside the
		// first-open gate, where it inherited that gate's lifetime: an app that names its first-open
		// event wrote it once per install, and a fresh App Store install has no receipt until the
		// first purchase — so that single write said "unknown" and the profile stayed "unknown" long
		// after the receipt arrived. The property describes the launch, not the install, so it goes
		// where the launch is.
		amplitude?.identify(userProperties: ["environment": environment])
		// AN-04 row 2: added unconditionally, because the plugin re-reads the ATT status on every
		// event anyway. An authorization that arrived before this call would otherwise be lost with
		// nothing to replay it — and the user only gives that answer once.
		addIDFAPluginOnce()
		trackFirstOpenOnce(event: firstOpenEvent)
	}

	func setUserId(_ userId: String) {
		// AN-03 row 6: the id itself, not the fact of the call. A split profile (row 3) is diagnosed
		// by holding the id from the log next to the one the dashboard shows — a line without the
		// value has nothing to hold up.
		debugLog(tag: Self.tag, "UserId: \(userId)")
		amplitude?.setUserId(userId: userId)
	}

	var deviceId: String? {
		let id = amplitude?.getDeviceId()
		// AN-03 row 6: `nil` is an `error`, not because reading failed — it is a legal answer twice
		// over (row 1) — but because it is the read that leaves Adapty without the link and never
		// retries (row 2). In a log that only said "device id was read", that moment is invisible.
		debugLog(tag: Self.tag, level: id == nil ? .error : .info, "DeviceId: \(id ?? "nil")")
		return id
	}

	func logEvent(_ event: String, properties: [String: Any]? = nil) {
		debugLog(tag: Self.tag, "LOG EVENT \(event).   Properties: \(String(describing: properties ?? [:]))")
		amplitude?.track(eventType: event, eventProperties: properties)
	}

	func setUserProperties(_ properties: [String: Any]) {
		// AN-03 row 6, in the shape settled 2026-09-10: one line per pair, not one dump of the whole
		// dictionary. A dictionary printed whole is unreadable past two keys, and a single pair is
		// what someone searches the console for when a property never showed up in the dashboard.
		for (key, value) in properties {
			debugLog(tag: Self.tag, "UserProperty: \(key) | value: \(value)")
		}
		amplitude?.identify(userProperties: properties)
	}

	/// The status itself is not read here: the plugin asks `ATTrackingManager` on every event, so a
	/// permission revoked later stops the IDFA on its own (AN-04 row 3). What this call does is make
	/// sure the plugin is in the chain at all.
	func updateTrackingAuthorization(_ status: ATTrackingManager.AuthorizationStatus) {
		addIDFAPluginOnce()
	}

	private func addIDFAPluginOnce() {
		guard let amplitude, !didAddIDFAPlugin else { return }
		didAddIDFAPlugin = true
		amplitude.add(plugin: AmplitudeIDFAPlugin())
	}

	/// Which install this is, as the dashboard has to be able to slice it.
	///
	/// AN-01 row 4: no receipt is "we cannot tell", not "production" — a fresh TestFlight install
	/// has no receipt until the first purchase or restore, and calling that cohort production mixes
	/// testers into the numbers the business reads.
	///
	/// AN-01 row 11: a debug build says so and stops there. Its receipt is whatever the last
	/// build-and-run left in the container, and knowing that is worth far less than being able to
	/// take developer traffic out of every number at once. The name stays `environment` — the app
	/// this package was extracted from already has dashboards on it, and renaming it is the app
	/// owner's call, not the package's.
	private var environment: String {
		guard !isDebug else { return "debug" }
		switch Bundle.main.appStoreReceiptURL?.lastPathComponent {
			case "sandboxReceipt": return "sandbox"
			case .some: return "production"
			case .none: return "unknown"
		}
	}

	private func trackFirstOpenOnce(event: String?) {
		guard !UserDefaults.standard.bool(forKey: Self.firstOpenTrackedKey) else { return }
		// AN-01 row 2: nothing to send is nothing to close. A build that ships before the app names
		// its first-open event would otherwise burn the gate for every install it touched, and the
		// version that finally names the event would never send it for that cohort.
		guard let event else { return }
		logEvent(event)
		// AN-01 row 1: the gate closes after the event is handed over, not before. The window is
		// small but it sits at the busiest moment in the app's life, and there is no second chance —
		// `track` itself only queues the event, so this is the earliest honest place to close it.
		UserDefaults.standard.set(true, forKey: Self.firstOpenTrackedKey)
	}
}
