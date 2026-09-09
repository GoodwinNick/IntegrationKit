//
//  AdaptyError.swift
//  IntegrationKit — Checks/Stubs
//
//  Stand-in for `AdaptyError` (Adapty 2.10.x). `ErrorCode` carries every case `AdaptyService`
//  switches on, with the real raw values: 0…14 are the raw `SKError` codes the SDK passes straight
//  through, 1000+ and 2000+ are Adapty's own. The numbers matter — the purchase verdict table is
//  written against them, and a check that named the wrong number would prove nothing.
//

import Foundation

public struct AdaptyError: Error, CustomDebugStringConvertible {
	public enum ErrorCode: Int {
		// Raw SKError values, passed through unwrapped.
		case unknown = 0
		case clientInvalid = 1
		case paymentCancelled = 2
		case paymentInvalid = 3
		case paymentNotAllowed = 4
		case storeProductNotAvailable = 5
		case invalidOfferIdentifier = 11
		case invalidSignature = 12
		case missingOfferParams = 13
		case invalidOfferPrice = 14

		// Adapty's own StoreKit-layer codes.
		case noProductIDsFound = 1000
		case productRequestFailed = 1002
		case cantMakePayments = 1003
		case cantReadReceipt = 1004
		case productPurchaseFailed = 1005

		// Adapty's own backend codes.
		case notActivated = 2002
		case badRequest = 2003
		case serverError = 2004
		case networkFailed = 2005
		case profileWasChanged = 3006
		case activateOnceError = 3005
	}

	public let adaptyErrorCode: ErrorCode

	public init(_ adaptyErrorCode: ErrorCode) {
		self.adaptyErrorCode = adaptyErrorCode
	}

	/// The real `AdaptyError` carries its human-readable text here and NOT in
	/// `localizedDescription` — it implements neither `LocalizedError` nor an
	/// `NSLocalizedDescriptionKey`, so Foundation builds the useless "domain error N" string
	/// instead. `AdaptyService` logs `String(reflecting:)` for exactly this reason (AD-04 row 6).
	public var debugDescription: String {
		"AdaptyError(\(adaptyErrorCode), code \(adaptyErrorCode.rawValue))"
	}
}
