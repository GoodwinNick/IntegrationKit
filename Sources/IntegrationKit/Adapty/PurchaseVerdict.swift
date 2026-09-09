//
//  PurchaseVerdict.swift
//  IntegrationKit
//

import Foundation

/// What Adapty answered about one purchase attempt. Internal to the package: `retryWithStoreKit`
/// is a signal that Adapty's own request failed (offline, bad product, server error), not a
/// premium decision, and the fallback it asks for happens inside `PremiumService.purchase` —
/// the app only ever sees the final `PurchaseOutcome`.
///
/// Named `PurchaseVerdict` since 0.3.0. It used to be `AdaptyPurchaseResult`, which is now the name
/// of an SDK type with a different meaning — three cases of one completed call, not our decision
/// about it — and two types with one name in one file is how the wrong one gets read.
///
/// AD-04: every branch here exists because one of them used to be missing. "Nothing happened" is
/// not a result — a purchase that hangs blocks every later one, and a purchase Apple already
/// charged for must never come back as an error the user can retry into a second charge.
enum PurchaseVerdict {
	case success
	case cancelled
	/// The purchase left the app and has not come back: "Ask to Buy" waiting for a parent's
	/// approval, or an SDK that never called its completion. Neither bought nor refused.
	case pending
	/// Adapty itself could not serve this purchase — the paywall was never loaded, or its own
	/// request failed before any payment was attempted.
	case retryWithStoreKit
	/// Failed, and a retry will not help: payments disabled on the device, product missing from
	/// this storefront, a promotional offer the store refuses to sign.
	case unavailable
	/// Failed, and trying again later is reasonable.
	case failed
}

// `paidUnconfirmed` is gone as of AD-04 row 9, and its removal is the one behaviour change of this
// release that can move money.
//
// On 2.10.x `makePurchase` answered `Result<Void, AdaptyError>`, so a purchase that completed and a
// purchase that never started were told apart only by an error code. Codes 2004 (serverError) and
// 2005 (networkFailed) were read as "Apple charged, Adapty could not confirm" and granted premium.
// But 2005 is also what a request that never left the device answers with — no payment sheet, no
// charge — and nothing in the error distinguishes the two. The verdict therefore handed premium to
// users who had not paid, for as long as the local grant lasts.
//
// 4.1.3 removes the guesswork: a purchase that completed comes back as
// `AdaptyPurchaseResult.success`, and an `AdaptyError` means it did not complete. A real payer whose
// confirmation was lost is still picked up — by the profile push and by `syncReceipt`, the paths
// that KNOW — so nothing is lost by refusing to guess here.
