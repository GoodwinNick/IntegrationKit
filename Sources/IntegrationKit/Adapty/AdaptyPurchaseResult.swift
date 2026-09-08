//
//  AdaptyPurchaseResult.swift
//  IntegrationKit
//

import Foundation

/// What Adapty answered about one purchase attempt. Internal to the package: `retryWithStoreKit`
/// is a signal that Adapty's own request failed (offline, bad product, server error), not a
/// premium decision, and the fallback it asks for happens inside `PremiumService.purchase` —
/// the app only ever sees the final `PurchaseOutcome`.
enum AdaptyPurchaseResult {
	case success
	case cancelled
	case retryWithStoreKit
	case failed
}
