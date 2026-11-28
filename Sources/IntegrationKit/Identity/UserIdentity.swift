//
//  UserIdentity.swift
//  IntegrationKit
//

import Foundation

/// Picks the user id from two Keychain slots: this app's own (account = its bundle id) and the one
/// shared by every app in the default access group. Nothing is kept in memory — every call reads.
///
/// Every read happens before the first write, so a read that fails leaves the Keychain exactly as
/// it was: an id that is only a stand-in must never land in a slot the real one may still reach.
struct UserIdentity {
	static let sharedAccount = "shared-user-id"
	private static let tag = "UserIdentity"

	let store: KeychainStoring
	let appAccount: String

	/// The app's own slot wins over everything once it is filled. Without it the shared id becomes
	/// the app's id; when there is no shared id yet, `existing` seeds it, or a fresh UUID does.
	func persistentUserId(existing: String?) -> String {
		let existing = existing.flatMap { $0.isEmpty ? nil : $0 }
		do {
			if let stored = try store.read(account: appAccount) {
				if let existing, existing != stored {
					debugLog(tag: Self.tag, "app id \(stored) from the app slot — the app's own \(existing) is ignored")
				} else {
					debugLog(tag: Self.tag, "app id \(stored) from the app slot")
				}
				return stored
			}
			let shared = try readOrCreateShared(seed: existing)
			save(shared, account: appAccount)
			if let existing, existing != shared {
				debugLog(tag: Self.tag, "app id \(shared) is the shared id — it replaces the app's own \(existing)")
			} else {
				debugLog(tag: Self.tag, "app id \(shared) is the shared id")
			}
			return shared
		} catch {
			let id = existing ?? UUID().uuidString
			debugLog(tag: Self.tag, level: .error, "app id: Keychain read failed, \(Self.describe(error)) — nothing written, returning \(existing == nil ? "a fresh unsaved id" : "the app's own id") \(id)")
			return id
		}
	}

	/// Read or create, never seeded: only `persistentUserId` knows when an app id may become shared.
	func sharedUserId() -> String {
		do {
			return try readOrCreateShared(seed: nil)
		} catch {
			let id = UUID().uuidString
			debugLog(tag: Self.tag, level: .error, "shared id: Keychain read failed, \(Self.describe(error)) — nothing written, returning a fresh unsaved id \(id)")
			return id
		}
	}

	private func readOrCreateShared(seed: String?) throws -> String {
		if let stored = try store.read(account: Self.sharedAccount) {
			debugLog(tag: Self.tag, "shared id \(stored) from the shared slot")
			return stored
		}
		let id = seed ?? UUID().uuidString
		debugLog(tag: Self.tag, "shared id \(id) created — \(seed == nil ? "a fresh UUID" : "seeded with the app's own id")")
		save(id, account: Self.sharedAccount)
		return id
	}

	/// A failed write is not retried: the value is still returned, and the app passes it back as
	/// `existing` on the next launch, where it seeds the same id.
	private func save(_ value: String, account: String) {
		do {
			try store.write(value, account: account)
		} catch {
			debugLog(tag: Self.tag, level: .error, "\(account): Keychain write failed, \(Self.describe(error))")
		}
	}

	private static func describe(_ error: Error) -> String {
		let error = error as NSError
		return "\(error.domain) \(error.code)"
	}
}
