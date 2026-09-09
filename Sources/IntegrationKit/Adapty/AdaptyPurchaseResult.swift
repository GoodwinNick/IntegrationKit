//
//  AdaptyPurchaseResult.swift
//  IntegrationKit
//

import Foundation

/// What Adapty answered about one purchase attempt. Internal to the package: `retryWithStoreKit`
/// is a signal that Adapty's own request failed (offline, bad product, server error), not a
/// premium decision, and the fallback it asks for happens inside `PremiumService.purchase` —
/// the app only ever sees the final `PurchaseOutcome`.
///
/// AD-04: every branch here exists because one of them used to be missing. "Nothing happened" is
/// not a result — a purchase that hangs blocks every later one, and a purchase Apple already
/// charged for must never come back as an error the user can retry into a second charge.
enum AdaptyPurchaseResult {
	case success
	case cancelled
	/// The purchase left the app and has not come back: "Ask to Buy" waiting for a parent's
	/// approval, or an SDK that never called its completion. Neither bought nor refused.
	case pending
	/// Apple took the money and Adapty could not confirm it (its server or the network failed
	/// after the transaction went through). Not an error for the user and never a reason to start
	/// a second purchase — the transaction is already in the payment queue and the profile push
	/// settles it.
	case paidUnconfirmed
	/// Adapty itself could not serve this purchase — the paywall was never loaded, or its own
	/// request failed before any payment was attempted.
	case retryWithStoreKit
	/// Failed, and a retry will not help: payments disabled on the device, product missing from
	/// this storefront, a promotional offer the store refuses to sign.
	case unavailable
	/// Failed, and trying again later is reasonable.
	case failed
}
