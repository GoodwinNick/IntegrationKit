//
//  AdaptyPaywall.swift
//  IntegrationKit — Checks/Stubs
//
//  Stand-in for `AdaptyPaywall` (Adapty 2.10.x). Only `remoteConfig` is here — the one field
//  `AdaptyService`'s remote-value reader touches.
//
//  `remoteConfig` is COMPUTED here, exactly as it is upstream: the real property runs
//  `JSONSerialization` over the paywall's config string on every single access, which is what
//  AD-07 row 5 is about. `parseCount` counts those parses so a check can prove the service reads
//  it once per loaded paywall instead of once per key.
//

import Foundation

public struct AdaptyPaywall {
	/// The raw JSON the dashboard stores, exactly as the SDK holds it.
	public let remoteConfigString: String?

	public static var parseCount = 0

	public init(remoteConfig: [String: Any]? = nil) {
		guard let remoteConfig,
		      let data = try? JSONSerialization.data(withJSONObject: remoteConfig),
		      let string = String(data: data, encoding: .utf8) else {
			self.remoteConfigString = nil
			return
		}
		self.remoteConfigString = string
	}

	/// Deliberately not cached — see the file comment.
	public var remoteConfig: [String: Any]? {
		guard let remoteConfigString, let data = remoteConfigString.data(using: .utf8) else { return nil }
		Self.parseCount += 1
		return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
	}
}
