//
//  AppleSubscribing.swift
//  IntegrationKit
//

import Foundation

/// The Apple side of the premium state. `StoreKitService` is the only implementation that ships;
/// the protocol stays because the premium logic has to be checkable with Apple's answers under
/// control (`Checks/Cases/PremiumBarrierCheck.swift`), which a hard-wired SDK call is not. Internal on
/// purpose — the app no longer supplies a StoreKit layer, it hands over its product ids and native
/// StoreKit 2 does the rest with no server-side secret to configure.
protocol AppleSubscribing: AnyObject {
	/// `nil` means the receipt could not be checked (offline, sandbox, verification error) —
	/// never "no subscription".
	func checkReceipt() async -> ReceiptAnswer?

	/// PM-10: the same question narrowed to `productIds` — one access level's products, so a product
	/// of another level cannot open this one. Same `nil` meaning as above.
	func checkReceipt(productIds: Set<String>) async -> ReceiptAnswer?

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

extension AppleSubscribing {
	// ponytail: an Apple side that cannot narrow answers for all its products — every level of a
	// map then hears the same receipt. Only `StoreKitService` narrows; the test-mode store and the
	// check fakes take this (an accepted TM-10 limit). Implement it where a level must not leak.
	func checkReceipt(productIds: Set<String>) async -> ReceiptAnswer? {
		await checkReceipt()
	}
}
