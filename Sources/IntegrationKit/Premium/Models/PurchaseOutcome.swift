//
//  PurchaseOutcome.swift
//  IntegrationKit
//

import Foundation

/// The result of a purchase attempt. `PremiumServicing.isPremium` already reflects `.purchased`
/// by the time the completion fires — the caller never needs to poll for it.
public enum PurchaseOutcome: Equatable, Sendable {
	case purchased
	/// The user said no.
	case cancelled
	/// Neither bought nor refused **yet**: waiting for a parent's approval ("Ask to Buy"), or paid
	/// and still being confirmed. Show waiting, not an error, and do not offer to buy again — the
	/// answer arrives on its own through the premium notification.
	case pending
	/// Buying is not possible on this device or for this product right now: payments are disabled,
	/// the product is missing from the storefront. Hide the button instead of offering a retry that
	/// will fail the same way.
	case unavailable
	/// Everything else that is not a purchase and not a user cancel, the StoreKit fallback
	/// included: when Adapty asks to retry through StoreKit, `PremiumService` runs that itself and
	/// reports its result here — "retry" never leaves the package.
	case failed
}
