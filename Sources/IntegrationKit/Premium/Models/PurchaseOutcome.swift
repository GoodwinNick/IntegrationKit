//
//  PurchaseOutcome.swift
//  IntegrationKit
//

import Foundation

/// The result of a purchase attempt. `PremiumServicing.isPremium` already reflects `.purchased`
/// by the time the completion fires — the caller never needs to poll for it.
public enum PurchaseOutcome: Equatable, Sendable {
	case purchased
	case cancelled
	/// Everything that is not a purchase and not a user cancel, the StoreKit fallback included:
	/// when Adapty asks to retry through StoreKit, `PremiumService` runs that itself and reports
	/// its result here — "retry" never leaves the package.
	case failed
}
