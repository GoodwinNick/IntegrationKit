//
//  SecurityKeychainStore.swift
//  IntegrationKit
//

import Foundation
import Security

/// Generic-password items under one service, synchronized through iCloud Keychain and readable from
/// the first unlock after a restart. `ThisDeviceOnly` is not an option: it cannot be combined with
/// `kSecAttrSynchronizable`. Without `kSecAttrSynchronizable: true` a query neither adds nor finds a
/// synchronized item, so the key is on reads as well as writes.
///
/// No access group is named. A new item lands in the app's default group — the first entry of its
/// `keychain-access-groups` entitlement — and a read searches every group the app belongs to. An app
/// shares these items with our other apps by listing the shared group first.
struct SecurityKeychainStore: KeychainStoring {
	private static let service = "IntegrationKit.UserIdentity"
	private static let tag = "UserIdentity"

	func read(account: String) throws -> String? {
		var query = Self.query(account: account)
		query[kSecReturnData as String] = true
		query[kSecMatchLimit as String] = kSecMatchLimitOne
		var result: CFTypeRef?
		let status = SecItemCopyMatching(query as CFDictionary, &result)
		if status == errSecItemNotFound {
			return nil
		}
		guard status == errSecSuccess, let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
			throw NSError(domain: NSOSStatusErrorDomain, code: Int(status == errSecSuccess ? errSecDecode : status))
		}
		return value
	}

	/// Asks for the stored attributes back, so the log can name the access group the item landed in —
	/// the one fact that says whether the shared group really is the app's first.
	func write(_ value: String, account: String) throws {
		var query = Self.query(account: account)
		query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
		query[kSecValueData as String] = Data(value.utf8)
		query[kSecReturnAttributes as String] = true
		var result: CFTypeRef?
		let status = SecItemAdd(query as CFDictionary, &result)
		guard status == errSecSuccess else {
			throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
		}
		let group = (result as? [String: Any])?[kSecAttrAccessGroup as String] as? String
		debugLog(tag: Self.tag, "\(account) saved to the Keychain, access group \(group ?? "unknown")")
	}

	private static func query(account: String) -> [String: Any] {
		[
			kSecClass as String: kSecClassGenericPassword,
			kSecAttrService as String: service,
			kSecAttrAccount as String: account,
			kSecAttrSynchronizable as String: true
		]
	}
}
