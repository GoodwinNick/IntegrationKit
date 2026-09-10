//
//  AdaptyRemoteConfig.swift
//  IntegrationKit — Checks/Stubs
//
//  Stand-in for `AdaptyRemoteConfig` (Adapty 4.1.3,
//  `Placements/Entities/AdaptyRemoteConfig.swift`). New in 4.x: 2.10.x hung a single
//  `remoteConfig: [String: Any]?` off the paywall, 4.1.3 hangs an ARRAY of these off the flow, one
//  per locale (`AdaptyFlow.swift:16`, decoded `?? []` at `:74`). AD-07 row 6 lives here — with more
//  than one entry, "which locale" stops being the SDK's decision and becomes ours.
//
//  `dictionary` is COMPUTED here, exactly as it is upstream (`:20-25`): the real property runs
//  `JSONSerialization` over the config string on every single access, which is what AD-07 row 5 is
//  about. `parseCount` counts those parses so a check can prove the service reads it once per loaded
//  flow instead of once per key.
//
//  Divergence: upstream `locale` is computed from an internal `AdaptyLocale` (`:11-15`). The stub
//  stores the string directly — `AdaptyLocale` has no public initialiser, and its normalisation
//  rules are the SDK's business, not ours.
//

import Foundation

public struct AdaptyRemoteConfig {
	public static var parseCount = 0

	public let locale: String
	/// A custom JSON string configured in Adapty Dashboard for this flow.
	public let jsonString: String

	public init(locale: String, jsonString: String) {
		self.locale = locale
		self.jsonString = jsonString
	}

	/// Convenience for checks: builds the JSON string the dashboard would have stored.
	public init(locale: String, dictionary: [String: Any]) {
		self.locale = locale
		guard let data = try? JSONSerialization.data(withJSONObject: dictionary),
		      let string = String(data: data, encoding: .utf8) else {
			self.jsonString = ""
			return
		}
		self.jsonString = string
	}

	/// Deliberately not cached — see the file comment.
	public var dictionary: [String: Any]? {
		guard let data = jsonString.data(using: .utf8) else { return nil }
		Self.parseCount += 1
		return try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
	}
}
