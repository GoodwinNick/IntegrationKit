//
//  AppleReceiptChecking.swift
//  IntegrationKit
//

import Foundation

/// The bit of StoreKit the premium state needs. `nil` means the receipt could not be checked
/// (sandbox, offline, verification error) — never "no subscription". The implementation lives
/// in the app: receipt validation is a StoreKit concern, not an integration one.
public protocol AppleReceiptChecking: AnyObject {
	func checkReceipt(completion: @escaping (Bool?) -> Void)
}
