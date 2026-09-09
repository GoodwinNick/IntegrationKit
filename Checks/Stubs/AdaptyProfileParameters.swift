//
//  AdaptyProfileParameters.swift
//  IntegrationKit — Checks/Stubs
//
//  Stand-in for `AdaptyProfileParameters` and its `Builder` (Adapty 2.10.x).
//
//  Unlike the first version, this one KEEPS what it is fed: AD-01 row 2, AD-06 rows 3, 5 and 6 all
//  assert on which values reached the SDK and which did not, and a builder that discards everything
//  can only ever prove that a call happened.
//
//  `with(customAttribute:forKey:)` throws upstream when the key or value breaks Adapty's rules, and
//  it throws here for the same inputs — the service is supposed to catch those before the builder
//  ever sees them, and a stub that never throws could not tell whether it does.
//

import AppTrackingTransparency
import Foundation

public struct AdaptyProfileParameters {
	public enum BuilderError: Error {
		case wrongKey(String)
		case wrongValue(String)
	}

	public final class Builder {
		public private(set) var customAttributes: [String: String] = [:]
		public private(set) var firebaseAppInstanceId: String?
		public private(set) var facebookAnonymousId: String?
		public private(set) var amplitudeUserId: String?
		public private(set) var amplitudeDeviceId: String?
		public private(set) var attStatus: ATTrackingManager.AuthorizationStatus?

		public init() {}

		/// Adapty's real rules, from `Entities/AdaptyProfile.CustomAttributes.swift`: a key is 1…30
		/// characters of `A-Za-z0-9._-`, a string value is 1…50 characters.
		@discardableResult
		public func with(customAttribute value: String, forKey key: String) throws -> Builder {
			guard !key.isEmpty, key.count <= 30, key.range(of: "[^A-Za-z0-9._-]", options: .regularExpression) == nil else {
				throw BuilderError.wrongKey(key)
			}
			guard !value.isEmpty, value.count <= 50 else {
				throw BuilderError.wrongValue(value)
			}
			customAttributes[key] = value
			return self
		}

		@discardableResult
		public func with(firebaseAppInstanceId value: String) -> Builder {
			firebaseAppInstanceId = value
			return self
		}

		@discardableResult
		public func with(facebookAnonymousId value: String) -> Builder {
			facebookAnonymousId = value
			return self
		}

		@discardableResult
		public func with(amplitudeUserId value: String) -> Builder {
			amplitudeUserId = value
			return self
		}

		@discardableResult
		public func with(amplitudeDeviceId value: String) -> Builder {
			amplitudeDeviceId = value
			return self
		}

		@discardableResult
		public func with(appTrackingTransparencyStatus value: ATTrackingManager.AuthorizationStatus) -> Builder {
			attStatus = value
			return self
		}

		public func build() -> AdaptyProfileParameters {
			AdaptyProfileParameters(
				customAttributes: customAttributes,
				firebaseAppInstanceId: firebaseAppInstanceId,
				facebookAnonymousId: facebookAnonymousId,
				amplitudeUserId: amplitudeUserId,
				amplitudeDeviceId: amplitudeDeviceId,
				attStatus: attStatus
			)
		}
	}

	public let customAttributes: [String: String]
	public let firebaseAppInstanceId: String?
	public let facebookAnonymousId: String?
	public let amplitudeUserId: String?
	public let amplitudeDeviceId: String?
	public let attStatus: ATTrackingManager.AuthorizationStatus?

	public init(
		customAttributes: [String: String] = [:],
		firebaseAppInstanceId: String? = nil,
		facebookAnonymousId: String? = nil,
		amplitudeUserId: String? = nil,
		amplitudeDeviceId: String? = nil,
		attStatus: ATTrackingManager.AuthorizationStatus? = nil
	) {
		self.customAttributes = customAttributes
		self.firebaseAppInstanceId = firebaseAppInstanceId
		self.facebookAnonymousId = facebookAnonymousId
		self.amplitudeUserId = amplitudeUserId
		self.amplitudeDeviceId = amplitudeDeviceId
		self.attStatus = attStatus
	}
}
