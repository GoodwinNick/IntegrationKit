//
//  KeychainStoring.swift
//  IntegrationKit
//

import Foundation

/// One string per account in the kit's own Keychain service. `read` answers `nil` only for an
/// account that holds nothing and throws for every other failure, so a caller can tell "empty" from
/// "could not look". `write` only ever adds: the user id slots are never updated or deleted.
protocol KeychainStoring {
	func read(account: String) throws -> String?
	func write(_ value: String, account: String) throws
}
