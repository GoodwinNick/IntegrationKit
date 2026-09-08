//
//  PurchaseOutcome.swift
//  IntegrationKit
//

import Foundation

/// The result of a purchase attempt. `PremiumServicing.isPremium` already reflects `.purchased`
/// by the time the completion fires — the caller never needs to poll for it.
public enum PurchaseOutcome: Equatable {
	case purchased
	case cancelled
	/// The request itself failed (offline, bad product, server error) — not a premium decision,
	/// just a signal to fall back to a StoreKit purchase path.
	case retryWithStoreKit
	case failed
	/// TEMPORARY: `PremiumService.purchase` is a stub until step 5 implements it. This case is
	/// removed once real purchase logic lands.
	case notImplemented
}
