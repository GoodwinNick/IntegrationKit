//
//  PaywallState.swift
//  IntegrationKit
//

import Foundation

/// Why a placement has no paywall yet — AD-02 row 5. `hasPaywall` answers `false` for both "still
/// loading" and "there is nothing there", and a screen cannot choose between a spinner and an
/// empty state from one boolean.
public enum PaywallState: Equatable, Sendable {
	/// The paywall is in the cache and can be shown.
	case ready
	/// An attempt is in flight or scheduled — show a spinner, ask again later.
	case loading
	/// Nothing is coming: the placement was never configured, or Adapty answered that it does not
	/// exist. Retrying will not change it.
	case unavailable
}
