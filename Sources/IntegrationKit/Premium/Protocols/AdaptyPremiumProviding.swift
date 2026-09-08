//
//  AdaptyPremiumProviding.swift
//  IntegrationKit
//

import Adapty
import Foundation

/// Adapty as a premium source. Internal to the package (spec 3.2/3.5): the only way to reach it
/// from outside is `PremiumServicing`, and `IntegrationKit.configure` is what builds the real one.
///
/// Deviates from the spec by one member: `hasPaywall(placement:)` is added here because
/// `PremiumServicing.hasPaywall` needs an internal source for it and the spec's snippet for
/// this protocol did not list one.
protocol AdaptyPremiumProviding: AnyObject {
	/// One-way push: Adapty sent a fresh profile on its own. Not part of any request/response
	/// pairing.
	var premiumObserver: ((AdaptyProfile) -> Void)? { get set }

	/// Asks for the current profile. `nil` means "did not answer" (network, error) — never
	/// "no premium".
	func profile() async -> AdaptyProfile?

	func products(placement: String) async -> [PremiumProduct]
	/// Adapty's own answer, `retryWithStoreKit` included — the fallback it asks for is run by
	/// `PremiumService`, so the app only ever sees a settled `PurchaseOutcome`.
	func buy(productId: String, placement: String) async -> AdaptyPurchaseResult
	func remoteValue<T>(placement: String, key: String) -> T?
	func logPaywallOpen(placement: String)
	func hasPaywall(placement: String) -> Bool

	/// Asks Adapty to upload the local receipt to its backend and refresh the profile. Called by
	/// `PremiumService.purchase` after a StoreKit-fallback purchase Adapty itself did not see.
	func syncReceipt()
}
