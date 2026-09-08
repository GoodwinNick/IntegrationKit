//
//  AdaptyError.swift
//  IntegrationKit — Checks/Stubs
//
//  Stand-in for `AdaptyError` (Adapty 2.10.x). `ErrorCode` carries every case
//  `AdaptyService.buyProduct` switches on, plus `notActivated` so that switch's `default:` branch
//  stays reachable instead of silently covering nothing.
//

import Foundation

public struct AdaptyError: Error {
	public enum ErrorCode {
		case paymentCancelled
		case productRequestFailed
		case serverError
		case unknown
		case productPurchaseFailed
		case notActivated
	}

	public let adaptyErrorCode: ErrorCode

	public init(_ adaptyErrorCode: ErrorCode) {
		self.adaptyErrorCode = adaptyErrorCode
	}
}
