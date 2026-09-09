//
//  AdaptyPremiumProviding.swift
//  IntegrationKit
//

import Adapty
import Foundation

/// Adapty as a premium source. Internal to the package (spec 3.2/3.5): the only way to reach it
/// from outside is `PremiumServicing`, and `IntegrationKit.configure` is what builds the real one.
///
/// Deviates from the spec by two members: `hasPaywall(placement:)` and `paywallState(placement:)`
/// are added here because `PremiumServicing` needs an internal source for them and the spec's
/// snippet for this protocol did not list one.
protocol AdaptyPremiumProviding: AnyObject {
	/// Whether the layer came up at all. `false` is permanent for the run — an empty key, a key that
	/// decrypted into something that is not one, a test run — and `docs/Integration.md` already
	/// states what it means: "Every call into the layer becomes a no-op".
	///
	/// Read by `PremiumService.products` (PM-07 row 12). "Adapty listed nothing" and "there is no
	/// Adapty" are not the same fact, and the price fallback is only right for the first: a dead
	/// layer cannot sell what it would be pricing, because `AdaptyService.buyProduct` refuses on
	/// this very flag.
	var isActive: Bool { get }

	/// One-way push: Adapty sent a fresh profile on its own. Not part of any request/response
	/// pairing.
	///
	/// The `Bool` is provenance. The first push of a process carries the profile the SDK had on
	/// disk from the last launch, delivered before any network request is made — `false` there, and
	/// an unverified "no premium" must not close access for a user whose subscription is alive
	/// (AD-05 row 2).
	var premiumObserver: ((AdaptyProfile, Bool) -> Void)? { get set }

	/// Asks for the current profile. `nil` means "did not answer" (network, error, an SDK that
	/// never called back) — never "no premium".
	func profile() async -> AdaptyProfile?

	/// Products of a placement, with the reason when there are none: "the paywall has not arrived"
	/// and "listing them failed" are different answers to a screen (AD-03 row 1).
	func products(placement: String) async -> AdaptyProductsAnswer

	/// Adapty's own answer, `retryWithStoreKit` included — the fallback it asks for is run by
	/// `PremiumService`, so the app only ever sees a settled `PurchaseOutcome`.
	func buy(productId: String, placement: String) async -> PurchaseVerdict

	func remoteValue<T>(placement: String, key: String) -> RemoteValue<T>
	func logPaywallOpen(placement: String)
	func hasPaywall(placement: String) -> Bool
	func paywallState(placement: String) -> PaywallState

	/// Asks Adapty to upload the local purchase to its backend and refresh the profile. Called by
	/// `PremiumService.purchase` after a StoreKit-fallback purchase Adapty itself did not see.
	func syncReceipt()

	/// One custom attribute on the Adapty profile, with the layer's own validation and traces
	/// (AD-06 row 3). `PremiumService.purchase` uses exactly one key, `purchasePlace`: the placement
	/// and the fact that money changed hands only meet there, and leaving that write to the app made
	/// it a thing every migration could forget (PM-04 row 14).
	func setProfileValue(value: String, key: String)
}
