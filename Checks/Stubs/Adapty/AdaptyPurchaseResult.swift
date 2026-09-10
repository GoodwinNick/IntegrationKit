//
//  AdaptyPurchaseResult.swift
//  IntegrationKit — Checks/Stubs
//
//  Stand-in for `AdaptyPurchaseResult` (Adapty 4.1.3,
//  `StoreKit/Entities/AdaptyPurchaseResult.swift`). The single biggest shape change of the
//  migration: 2.10.x answered `makePurchase` with `Result<Void, AdaptyError>`, so "cancelled" and
//  "waiting for a parent's approval" arrived as ERROR CODES and had to be decoded from a table
//  (AD-04 rows 3 and 9). 4.1.3 answers with `Result<AdaptyPurchaseResult, AdaptyError>`, and the
//  three outcomes that are not failures are cases of their own.
//
//  Divergence, unavoidable: upstream the success case carries
//  `StoreKit.VerificationResult<StoreKit.Transaction>` (`:16`), which has no public initialiser — a
//  harness cannot build one, and therefore could not reach the success path at all. The stub
//  substitutes `SignedTransaction`, a marker type of its own.
//
//  The consequence is a rule for `AdaptyService`: read this value ONLY through the accessors below
//  (`profile`, `isPurchaseCancelled`, `isPurchasePending`, `isPurchaseSuccess`), which upstream
//  provides for exactly this purpose (`:18-52`). Code that destructures `case .success(let profile,
//  let transaction)` and then reads something off `transaction` compiles here and lies here — the
//  payload is not the real one.
//

import Foundation

public enum AdaptyPurchaseResult {
	/// See the file comment: this is NOT `StoreKit.VerificationResult<Transaction>`.
	public struct SignedTransaction {
		public let id: UInt64

		public init(id: UInt64 = 1) {
			self.id = id
		}
	}

	/// The user cancelled the purchase.
	case userCancelled
	/// The purchase is pending some user action — "Ask to Buy" waiting for a parent, or SCA.
	case pending
	/// The purchase succeeded, with a profile that already reflects it.
	case success(profile: AdaptyProfile, transaction: SignedTransaction)

	public var isPurchaseCancelled: Bool {
		if case .userCancelled = self { true } else { false }
	}

	public var isPurchasePending: Bool {
		if case .pending = self { true } else { false }
	}

	public var isPurchaseSuccess: Bool {
		if case .success = self { true } else { false }
	}

	/// The up-to-date profile, or `nil` for the two non-success cases.
	public var profile: AdaptyProfile? {
		guard case let .success(profile, _) = self else { return nil }
		return profile
	}

	public var signedTransaction: SignedTransaction? {
		guard case let .success(_, transaction) = self else { return nil }
		return transaction
	}
}
