//
//  Amplitude.swift
//  IntegrationKit — Checks/Stubs/AmplitudeSwift
//
//  Stand-in for the `Amplitude` SDK class (Amplitude-Swift 1.18.x). Compiled into a module called
//  `AmplitudeSwift` alongside the other files in this folder, so `AmplitudeAnalytics` and
//  `AmplitudeIDFAPlugin` build and run outside Xcode with their `import AmplitudeSwift` untouched.
//
//  `AmplitudeAnalytics` keeps its own `Amplitude` instance private, so every call this stub
//  receives is recorded on static vars instead of instance state — same idea as the `Adapty`
//  stub, because that's the only way a check can observe what happened. `reset()` clears every
//  recording; call it at the top of each row so one row's setup cannot leak into the next.
//

import Foundation

public final class Amplitude {
	public static private(set) var lastUserId: String?
	public static private(set) var trackedEvents: [(eventType: String, properties: [String: Any]?)] = []
	public static private(set) var identifyCalls: [[String: Any]] = []
	public static private(set) var addedPluginCount = 0

	/// What `getDeviceId()` answers. Settable so a check can seed it before `configure()` runs.
	public static var deviceId: String? = "stub-device-id"

	public static func reset() {
		lastUserId = nil
		trackedEvents = []
		identifyCalls = []
		addedPluginCount = 0
		deviceId = "stub-device-id"
	}

	public init(configuration: Configuration) {}

	public func setUserId(userId: String) {
		Amplitude.lastUserId = userId
	}

	public func getDeviceId() -> String? {
		Amplitude.deviceId
	}

	public func track(eventType: String, eventProperties: [String: Any]? = nil) {
		Amplitude.trackedEvents.append((eventType, eventProperties))
	}

	public func identify(userProperties: [String: Any]) {
		Amplitude.identifyCalls.append(userProperties)
	}

	public func add(plugin: EnrichmentPlugin) {
		Amplitude.addedPluginCount += 1
	}
}
