//
//  IntegrationKit+UserIdentity.swift
//  IntegrationKit
//

import Foundation

public extension IntegrationKit {
	/// The id this app passes to `configure(deviceId:)`. It survives deleting and reinstalling the app, and it is the same across our apps that share
	/// a Keychain access group. Static, so it is called before `configure`.
	///
	/// Resolution, first match wins:
	/// 1. This app's own Keychain slot holds an id — that id, whatever `existing` says.
	/// 2. Otherwise the shared id becomes this app's id and is saved to its slot. When there is no
	///    shared id yet, `existing` seeds it (so the first app to update keeps its current id), or a
	///    fresh UUID does.
	/// 3. A Keychain read fails with anything but "not found" — nothing is written, and the answer is
	///    `existing`, or a fresh unsaved UUID when there is none.
	///
	/// `existing` is the id the app already keeps itself, or `nil`; an empty string counts as `nil`.
	/// The answer can differ from it — store the answer as the app's id and use only that.
	///
	/// Sharing needs the app's Keychain Sharing capability with the shared group listed **first**:
	/// the items are written without an access group, so they land in the app's default group.
	static func persistentUserId(existing: String?) -> String {
		UserIdentity(store: SecurityKeychainStore(), appAccount: Bundle.main.bundleIdentifier ?? "").persistentUserId(existing: existing)
	}

	/// The id shared by our apps in the same Keychain access group: read, or created once and saved.
	/// ``persistentUserId(existing:)`` already makes it the app's id; this is for an app that needs
	/// the shared id on its own. A Keychain read that fails answers with a fresh unsaved UUID, which
	/// is not the shared id and must not be stored as one.
	static func sharedUserId() -> String {
		UserIdentity(store: SecurityKeychainStore(), appAccount: Bundle.main.bundleIdentifier ?? "").sharedUserId()
	}
}
