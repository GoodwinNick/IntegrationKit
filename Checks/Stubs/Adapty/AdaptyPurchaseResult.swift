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
//  substitutes `SignedTransaction`, an enum of its own with the SAME two cases upstream's
//  `VerificationResult` has (`.verified(payload)`, `.unverified(payload, error)`), so the pattern
//  `case .verified(let transaction)? = result.signedTransaction` compiles against both. That
//  pattern is how `AdaptyService` reads the transaction since 0.8.0 (FA-04): only a verified one
//  goes to Firebase.
//
//  The rule that still holds: do NOT read `transaction` (upstream `:63-65`, the unverified-tolerant
//  `unsafePayloadValue`) — it does not exist here, and upstream it would also answer for a payload
//  nobody verified (`FA-04 Ризики` row 4). Everything else is read through the accessors below
//  (`profile`, `isPurchaseCancelled`, `isPurchasePending`, `isPurchaseSuccess`, `signedTransaction`),
//  which upstream provides for exactly this purpose (`:18-60`). The payload inside `.verified` is a
//  stand-in too — `Payload` here, `StoreKit.Transaction` upstream.
//

import Foundation

public enum AdaptyPurchaseResult {
	/// Stands for `StoreKit.Transaction`, which a harness cannot build.
	public struct Payload {
		public let id: UInt64

		public init(id: UInt64 = 1) {
			self.id = id
		}
	}

	/// See the file comment: this is NOT `StoreKit.VerificationResult<Transaction>`, but it has its
	/// two cases. The `init(id:)` keeps every older call site (`SignedTransaction()`) compiling and
	/// builds the verified case, which is what a purchase that went through looks like.
	public enum SignedTransaction {
		case verified(Payload)
		case unverified(Payload, Error)

		public init(id: UInt64 = 1) {
			self = .verified(Payload(id: id))
		}

		public var id: UInt64 {
			switch self {
				case .verified(let payload), .unverified(let payload, _): return payload.id
			}
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
