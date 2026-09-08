//
//  AdaptyPremiumProviding.swift
//  IntegrationKit
//

import Adapty
import Foundation

/// Adapty as a premium source. The spec (3.2) marks this internal to the package — the only
/// way to reach it from outside is meant to be `PremiumServicing`. Kept `public` for now: while
/// `PremiumService.init` still takes this as a constructor parameter (steps 0-5), demoting it
/// to internal is a "public init exposing an internal type" compile error. Step 6 ("removing
/// `AdaptyServicing` from the public API") is what actually closes this boundary, by having the
/// package build its own Adapty source internally instead of taking one through `init`.
///
/// Deviates from the spec by one member: `hasPaywall(placement:)` is added here because
/// `PremiumServicing.hasPaywall` needs an internal source for it and the spec's snippet for
/// this protocol did not list one.
public protocol AdaptyPremiumProviding: AnyObject {
	/// One-way push: Adapty sent a fresh profile on its own. Not part of any request/response
	/// pairing.
	var premiumObserver: ((AdaptyProfile) -> Void)? { get set }

	/// Asks for the current profile. `nil` means "did not answer" (network, error) — never
	/// "no premium".
	func profile() async -> AdaptyProfile?

	func products(placement: String) async -> [PremiumProduct]
	func buy(productId: String, placement: String) async -> PurchaseOutcome
	func remoteValue<T>(placement: String, key: String) -> T?
	func logPaywallOpen(placement: String)
	func hasPaywall(placement: String) -> Bool
}
