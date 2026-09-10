//
//  AdaptyProfileParameters.swift
//  IntegrationKit — Checks/Stubs
//
//  Stand-in for `AdaptyProfileParameters` and its `Builder` (Adapty 4.1.3,
//  `Profile/Entities/AdaptyProfileParameters.Builder.swift`).
//
//  Unlike a naive stub, this one KEEPS what it is fed: AD-01 row 2, AD-06 rows 3, 5 and 6 all assert
//  on which values reached the SDK and which did not, and a builder that discards everything can
//  only ever prove that a call happened.
//
//  Four setters that 2.10.x had are GONE in 4.1.3 and gone from here:
//  `with(firebaseAppInstanceId:)`, `with(facebookAnonymousId:)`, `with(amplitudeUserId:)` and
//  `with(amplitudeDeviceId:)`. Those four ids now travel through `setIntegrationIdentifier`
//  (`AdaptyIntegrationIdentifier.swift`) instead — a different call, a different failure mode, and
//  no longer part of the profile write. `AdaptyService.linkAmplitudeUserId` is written against the
//  deleted pair and cannot compile until it moves.
//
//  What the builder does with what it is given, reproduced from upstream because every line of it is
//  a behaviour some row depends on:
//
//  * The key is TRIMMED and then validated: 1…30 characters of `A-Za-z0-9._-`
//    (`AdaptyProfile.CustomAttributes.swift:64-68`).
//  * A string value is trimmed, and an EMPTY result is not an error — it becomes `.none`, which
//    REMOVES the attribute (`Builder.swift:85-88`). Only a non-empty value longer than 50 characters
//    throws (`CustomAttributes.swift:41-50`). A service that expects `""` to be rejected is wrong
//    about which of its own guards is load-bearing.
//  * The 30-attribute ceiling is checked on every write (`:70-74`, called at `Builder.swift:102`).
//  * Every one of those throws is a TYPED `throws(AdaptyError)` carrying `.wrongParam` — not a
//    builder-specific error type, which is what 2.10.x's stub modelled.
//
//  `with(appTrackingTransparencyStatus:)` now takes an OPTIONAL (`Builder.swift:136`); passing `nil`
//  clears the field instead of failing to compile.
//

import AppTrackingTransparency
import Foundation

public struct AdaptyProfileParameters {
	/// Mirrors `AdaptyProfile.CustomAttributeValue`. `.none` is a removal, not an absence.
	public enum CustomAttributeValue: Equatable {
		case none
		case string(String)
		case double(Double)
	}

	public final class Builder {
		private var parameters = AdaptyProfileParameters()

		public init() {}

		@discardableResult
		public func with(customAttribute value: String, forKey key: String) throws(AdaptyError) -> Builder {
			let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
			guard !trimmed.isEmpty else {
				return try with(customAttribute: .none, forKey: key)
			}
			return try with(customAttribute: .string(trimmed), forKey: key)
		}

		@discardableResult
		public func with(customAttribute value: Double, forKey key: String) throws(AdaptyError) -> Builder {
			try with(customAttribute: .double(value), forKey: key)
		}

		@discardableResult
		public func withRemoved(customAttributeForKey key: String) throws(AdaptyError) -> Builder {
			try with(customAttribute: .none, forKey: key)
		}

		private func with(customAttribute value: CustomAttributeValue, forKey key: String) throws(AdaptyError) -> Builder {
			let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
			guard !key.isEmpty, key.count <= 30,
			      key.range(of: ".*[^A-Za-z0-9._-].*", options: .regularExpression) == nil else {
				throw AdaptyError(.wrongParam)
			}
			if case let .string(string) = value, string.count > 50 {
				throw AdaptyError(.wrongParam)
			}
			parameters.customAttributes[key] = value
			guard parameters.customAttributes.filter({ $0.value != .none }).count <= 30 else {
				throw AdaptyError(.wrongParam)
			}
			return self
		}

		@discardableResult
		public func with(appTrackingTransparencyStatus value: ATTrackingManager.AuthorizationStatus?) -> Builder {
			parameters.attStatus = value
			return self
		}

		public func build() -> AdaptyProfileParameters {
			parameters
		}
	}

	public private(set) var customAttributes: [String: CustomAttributeValue] = [:]
	public private(set) var attStatus: ATTrackingManager.AuthorizationStatus?

	public init() {}
}
