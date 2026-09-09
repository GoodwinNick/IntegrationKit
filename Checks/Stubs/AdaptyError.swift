//
//  AdaptyError.swift
//  IntegrationKit — Checks/Stubs
//
//  Stand-in for `AdaptyError` (Adapty 4.1.3, `Errors/AdaptyError.swift:24-106`). `ErrorCode` carries
//  every case the SDK defines, with the real raw values: 0…14 are the raw `SKError` codes the SDK
//  passes straight through, 1000+ and 2000+ are Adapty's own. The numbers matter — the purchase
//  verdict table is written against them, and a check that named the wrong number would prove
//  nothing.
//
//  Two of them were WRONG in the 2.10.x stub and are fixed here: `cantReadReceipt` is 1005, not
//  1004, and `productPurchaseFailed` is 1006, not 1005. Nothing in `AdaptyService` reads a raw
//  value, so the mistake was invisible — until someone reads the stub to learn the numbers.
//
//  Two divergences from 4.1.3, both unavoidable in a harness:
//
//  * The real `AdaptyError` is a struct wrapping an internal `CustomAdaptyError` and its only
//    initialiser is `package` — nothing outside the SDK can build one. The stub keeps a public
//    `init(_:)`, because a check that cannot construct an error cannot exercise a failure path.
//  * The real type is `CustomNSError`; the stub is a plain `Error`. `AdaptyService` never bridges to
//    `NSError`, so nothing is lost, and dragging `errorUserInfo` in would only add code no check
//    reads.
//
//  What is NOT a divergence any more: 4.1.3 conforms to `CustomStringConvertible` as well as
//  `CustomDebugStringConvertible` (`:109`), so `String(describing:)` finally produces the real text.
//  `AdaptyService` still logs `String(reflecting:)` (AD-04 row 6) — `localizedDescription` is still
//  the useless "domain error N", because there is still no `LocalizedError` conformance.
//

import Foundation

public struct AdaptyError: Error, CustomStringConvertible, CustomDebugStringConvertible {
	public enum ErrorCode: Int, Sendable {
		// Raw SKError values, passed through unwrapped.
		case unknown = 0
		case clientInvalid = 1
		case paymentCancelled = 2
		case paymentInvalid = 3
		case paymentNotAllowed = 4
		case storeProductNotAvailable = 5
		case cloudServicePermissionDenied = 6
		case cloudServiceNetworkConnectionFailed = 7
		case cloudServiceRevoked = 8
		case privacyAcknowledgementRequired = 9
		case unauthorizedRequestData = 10
		case invalidOfferIdentifier = 11
		case invalidSignature = 12
		case missingOfferParams = 13
		case invalidOfferPrice = 14

		// Adapty's own StoreKit-layer codes.
		case noProductIDsFound = 1000
		case productRequestFailed = 1002
		case cantMakePayments = 1003
		case cantReadReceipt = 1005
		case productPurchaseFailed = 1006
		case refreshReceiptFailed = 1010
		case fetchSubscriptionStatusFailed = 1020
		case unknownTransactionId = 1030
		case paymentPendingError = 1050

		// Adapty's own backend codes.
		case notActivated = 2002
		case badRequest = 2003
		case serverError = 2004
		case networkFailed = 2005
		case decodingFailed = 2006
		case encodingFailed = 2009

		// Adapty's own client-side codes.
		case analyticsDisabled = 3000
		/// What `updateExternalAttribution` answers with when the payload will not serialise
		/// (`.wrongAttributeData`, built at `InternalAdaptyError.swift:234-241`), and what the profile
		/// builder throws for a bad custom-attribute key or value. AD-06 row 11 turns on this code
		/// being permanent: re-queueing it retries the same unserialisable payload forever.
		case wrongParam = 3001
		case activateOnceError = 3005
		case profileWasChanged = 3006
		case unsupportedData = 3007
		case unidentifiedUserLogout = 3020
		case fetchTimeoutError = 3101

		case operationInterrupted = 9000
	}

	public let adaptyErrorCode: ErrorCode

	public init(_ adaptyErrorCode: ErrorCode) {
		self.adaptyErrorCode = adaptyErrorCode
	}

	public var description: String {
		"AdaptyError(\(adaptyErrorCode), code \(adaptyErrorCode.rawValue))"
	}

	/// The real `AdaptyError` carries its human-readable text here and NOT in
	/// `localizedDescription` — it implements neither `LocalizedError` nor an
	/// `NSLocalizedDescriptionKey`, so Foundation builds the useless "domain error N" string
	/// instead. `AdaptyService` logs `String(reflecting:)` for exactly this reason (AD-04 row 6).
	public var debugDescription: String { description }
}
