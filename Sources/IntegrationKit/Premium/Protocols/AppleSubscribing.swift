//
//  AppleSubscribing.swift
//  IntegrationKit
//

import Foundation

/// The Apple side of the premium state. `StoreKitService` is the only implementation that ships;
/// the protocol stays because the premium logic has to be checkable with Apple's answers under
/// control (`Checks/PremiumBarrierCheck.swift`), which a hard-wired SDK call is not. Internal on
/// purpose — the app no longer supplies a StoreKit layer, it hands over a shared secret and its
/// product ids.
protocol AppleSubscribing: AnyObject {
	/// `nil` means the receipt could not be checked (offline, sandbox, verification error) —
	/// never "no subscription".
	func checkReceipt() async -> Bool?

	/// Restore on the StoreKit side. Premium is turned on by `PremiumService` afterwards, not
	/// by this call.
	func restore() async -> RestoreOutcome

	/// The fallback purchase, used when Adapty's own request failed. `PremiumService.purchase`
	/// calls it — the app never buys past the facade, so there is still exactly one verdict.
	func purchase(productId: String) async -> PurchaseOutcome

	/// Prices for the ids a paywall lists. A missing key means the store said nothing about that
	/// id (not approved yet, wrong bundle, offline) — never an empty price to show.
	func products(ids: Set<String>) async -> [String: PremiumProduct]
}
