//
//  AdaptyProfileParameters.swift
//  IntegrationKit — Checks/Stubs
//
//  Stand-in for `AdaptyProfileParameters` and its `Builder` (Adapty 2.10.x). Every `with(...)`
//  overload `AdaptyService` chains off of is here; `with(customAttribute:forKey:)` is `throws`
//  upstream, so it stays `throws` here even though this stub never actually throws.
//
//  ponytail: `Builder` discards every value it is fed — no check here inspects an outgoing profile
//  parameter. Add storage (and read it back on `AdaptyProfileParameters`) when one needs to.
//

import AppTrackingTransparency
import Foundation

public struct AdaptyProfileParameters {
	public final class Builder {
		public init() {}

		@discardableResult
		public func with(customAttribute value: String, forKey key: String) throws -> Builder {
			self
		}

		@discardableResult
		public func with(firebaseAppInstanceId value: String) -> Builder {
			self
		}

		@discardableResult
		public func with(facebookAnonymousId value: String) -> Builder {
			self
		}

		@discardableResult
		public func with(amplitudeUserId value: String) -> Builder {
			self
		}

		@discardableResult
		public func with(amplitudeDeviceId value: String) -> Builder {
			self
		}

		@discardableResult
		public func with(appTrackingTransparencyStatus value: ATTrackingManager.AuthorizationStatus) -> Builder {
			self
		}

		public func build() -> AdaptyProfileParameters {
			AdaptyProfileParameters()
		}
	}

	public init() {}
}
