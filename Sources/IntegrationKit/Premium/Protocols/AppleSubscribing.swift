//
//  AppleSubscribing.swift
//  IntegrationKit
//

import Foundation

/// The Apple side of the premium state. The app supplies the implementation — StoreKit is its
/// zone — the package only describes the role in full.
public protocol AppleSubscribing: AnyObject {
	/// `nil` means the receipt could not be checked (offline, sandbox, verification error) —
	/// never "no subscription".
	func checkReceipt() async -> Bool?

	/// Restore on the StoreKit side. Premium is turned on by `PremiumService` afterwards, not
	/// by this call.
	func restore() async -> RestoreOutcome
}
