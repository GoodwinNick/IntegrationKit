//
//  UserIdentityCheck.swift
//  IntegrationKit
//
//  Written from the approved schemas UI-01 (the app's id) and UI-02 (the shared id). The rules run
//  against an in-memory `KeychainStoring`, so nothing here reads or writes the real Keychain; what
//  the real store sends to `SecItem*` (synchronizable, AfterFirstUnlock, no access group — UI-01
//  rows 9 and 10, UI-02 rows 1 and 7) is not observable from here.
//
//  Built WITHOUT `-D DEBUG`, so every trace is read through `debugLogSink`. Every row runs and every
//  failure is collected; a non-zero exit is a regression.
//  Run:  ./Checks/user-identity-check.sh
//

import Foundation

@main
enum UserIdentityCheck {
	static var failures: [String] = []

	static func check(_ condition: @autoclosure () -> Bool, _ message: @autoclosure () -> String) {
		guard !condition() else { return }
		let text = message()
		failures.append(text)
		print("FAILED: \(text)")
	}

	/// The Keychain as two dictionaries: what is stored per account, and which accounts answer with
	/// an error instead. Every successful write is recorded in order, so a row can say exactly what
	/// was written and where.
	final class FakeKeychain: KeychainStoring {
		var items: [String: String] = [:]
		var readErrors: [String: Error] = [:]
		var writeError: Error?
		var writes: [(account: String, value: String)] = []

		func read(account: String) throws -> String? {
			if let error = readErrors[account] { throw error }
			return items[account]
		}

		func write(_ value: String, account: String) throws {
			if let writeError { throw writeError }
			items[account] = value
			writes.append((account, value))
		}
	}

	static let app = "com.example.app"
	static let otherApp = "com.example.other"
	static let shared = UserIdentity.sharedAccount
	/// `errSecInteractionNotAllowed`, the answer a read gets before the first unlock after a restart.
	static let locked = NSError(domain: NSOSStatusErrorDomain, code: -25308)
	/// `errSecIO`, for a write that fails.
	static let ioError = NSError(domain: NSOSStatusErrorDomain, code: -36)

	static func identity(_ store: FakeKeychain, account: String = app) -> UserIdentity {
		UserIdentity(store: store, appAccount: account)
	}

	static func isUUID(_ value: String) -> Bool {
		UUID(uuidString: value) != nil
	}

	static func captureLog() -> () -> [String] {
		var lines: [String] = []
		debugLogSink = { lines.append($0) }
		return { lines }
	}

	static func main() {
		// T1 UI-01 (a), row 2: the app's own slot wins over everything, `existing` included.
		do {
			let store = FakeKeychain()
			store.items = [app: "K", shared: "S"]
			let id = identity(store).persistentUserId(existing: "A")
			check(id == "K", "T1 UI-01 (a): a filled app slot must be returned even when existing differs, got \(id)")
			check(store.writes.isEmpty, "T1 UI-01 (a): a filled app slot must leave the Keychain untouched, got writes \(store.writes)")
		}

		// T2 UI-01 (b), rows 1-2: no app slot, the shared id is there — it becomes this app's id,
		// whatever the app had before.
		do {
			let store = FakeKeychain()
			store.items = [shared: "S"]
			let id = identity(store).persistentUserId(existing: "A")
			check(id == "S", "T2 UI-01 (b): the shared id must become the app id even when existing differs, got \(id)")
			check(store.items[app] == "S", "T2 UI-01 (b): the shared id must be saved to the app slot, got \(String(describing: store.items[app]))")
			check(store.items[shared] == "S", "T2 UI-01 (b): the shared slot must not change, got \(String(describing: store.items[shared]))")
			check(store.writes.count == 1, "T2 UI-01 (b): exactly one write, the app slot, got \(store.writes)")
		}

		// T3 UI-01 (c), row 1: nothing anywhere and the app has an id — that id seeds the shared slot,
		// so the first app to update keeps the id it already had.
		do {
			let store = FakeKeychain()
			let id = identity(store).persistentUserId(existing: "A")
			check(id == "A", "T3 UI-01 (c): existing must be returned when it seeds the shared id, got \(id)")
			check(store.items[shared] == "A", "T3 UI-01 (c): existing must seed the shared slot, got \(String(describing: store.items[shared]))")
			check(store.items[app] == "A", "T3 UI-01 (c): existing must be saved to the app slot, got \(String(describing: store.items[app]))")
			check(store.writes.map { $0.account } == [shared, app], "T3 UI-01 (c): the shared slot first, then the app slot, got \(store.writes)")

			// T4 UI-01 row 8, the model of a reinstall: the app lost its own storage, the Keychain did
			// not — the same id comes back and nothing more is written.
			let again = identity(store).persistentUserId(existing: nil)
			check(again == "A", "T4 UI-01 row 8: after a reinstall the id must be the one from the Keychain, got \(again)")
			check(store.writes.count == 2, "T4 UI-01 row 8: a reinstall must write nothing, got \(store.writes)")

			// T5 UI-02 steady state through UI-01: a second app on the same Keychain, with an id of its
			// own, ends up on the same shared id.
			let other = identity(store, account: otherApp).persistentUserId(existing: "B")
			check(other == "A", "T5 UI-01 (b): a second app must take the shared id over its own, got \(other)")
			check(store.items[otherApp] == "A", "T5 UI-01 (b): the second app's slot must hold the shared id, got \(String(describing: store.items[otherApp]))")
		}

		// T6 UI-01 (d): nothing anywhere, no id in the app — one fresh UUID in both slots.
		do {
			let store = FakeKeychain()
			let id = identity(store).persistentUserId(existing: nil)
			check(isUUID(id), "T6 UI-01 (d): a fresh id must be a UUID string, got \(id)")
			check(store.items[shared] == id && store.items[app] == id, "T6 UI-01 (d): the fresh id must be saved to both slots, got \(store.items)")
		}

		// T7 UI-01 row 5: an empty `existing` is no id at all — it must never seed the shared slot.
		do {
			let store = FakeKeychain()
			let id = identity(store).persistentUserId(existing: "")
			check(isUUID(id), "T7 UI-01 row 5: an empty existing must be treated as none, got \"\(id)\"")
			check(store.items[shared] == id, "T7 UI-01 row 5: the shared slot must hold the fresh id, not \"\", got \(String(describing: store.items[shared]))")
		}

		// T8-T10 UI-01 (e), row 3: a read that fails with anything but "not found" writes nothing.
		do {
			let store = FakeKeychain()
			store.readErrors = [app: locked]
			let log = captureLog()
			let id = identity(store).persistentUserId(existing: "A")
			debugLogSink = nil
			check(id == "A", "T8 UI-01 (e): a failed read must return existing, got \(id)")
			check(store.writes.isEmpty, "T8 UI-01 (e): a failed read must write nothing, got \(store.writes)")
			check(
				log().contains { $0.contains("[UserIdentity][error]") && $0.contains("-25308") },
				"T8 UI-01 row 3: a failed read must leave an error line naming the code -25308, got \(log())"
			)
		}
		do {
			let store = FakeKeychain()
			store.readErrors = [app: locked]
			let id = identity(store).persistentUserId(existing: nil)
			check(isUUID(id), "T9 UI-01 (e): a failed read with no existing must return a fresh UUID, got \(id)")
			check(store.writes.isEmpty, "T9 UI-01 (e): the fresh id after a failed read must not be saved, got \(store.writes)")
		}
		do {
			let store = FakeKeychain()
			store.readErrors = [shared: locked]
			let id = identity(store).persistentUserId(existing: "A")
			check(id == "A", "T10 UI-01 (e): a failed shared read must return existing, got \(id)")
			check(store.writes.isEmpty, "T10 UI-01 (e): a failed shared read must write nothing, not even the app slot, got \(store.writes)")
		}

		// T11 UI-01 row 4: a failed write still answers, says so, and the next launch lands on the
		// same id.
		do {
			let store = FakeKeychain()
			store.writeError = ioError
			let log = captureLog()
			let id = identity(store).persistentUserId(existing: "A")
			debugLogSink = nil
			check(id == "A", "T11 UI-01 row 4: a failed write must still return the id, got \(id)")
			check(
				log().contains { $0.contains("[UserIdentity][error]") && $0.contains("-36") },
				"T11 UI-01 row 4: a failed write must leave an error line naming the code, got \(log())"
			)
			store.writeError = nil
			let next = identity(store).persistentUserId(existing: id)
			check(next == "A" && store.items[app] == "A", "T11 UI-01 row 4: the next launch must save and keep the same id, got \(next), \(store.items)")
		}

		// T12 UI-02: read or create once, then stable; the app slot is never touched.
		do {
			let store = FakeKeychain()
			let first = identity(store).sharedUserId()
			let second = identity(store).sharedUserId()
			check(isUUID(first), "T12 UI-02: a created shared id must be a UUID string, got \(first)")
			check(first == second, "T12 UI-02: the shared id must be stable across calls, got \(first) then \(second)")
			check(store.writes.count == 1 && store.writes.first?.account == shared, "T12 UI-02: exactly one write, to the shared slot, got \(store.writes)")
			check(store.items[app] == nil, "T12 UI-02: the app slot must not be touched, got \(String(describing: store.items[app]))")
		}
		do {
			let store = FakeKeychain()
			store.items = [shared: "S"]
			let id = identity(store).sharedUserId()
			check(id == "S" && store.writes.isEmpty, "T13 UI-02: an existing shared id must be returned with nothing written, got \(id), \(store.writes)")
		}

		// T14 UI-02, no seeding: `sharedUserId()` never turns the app's id into the shared one.
		do {
			let store = FakeKeychain()
			store.items = [app: "K"]
			let id = identity(store).sharedUserId()
			check(id != "K" && isUUID(id), "T14 UI-02: the shared id must be a fresh UUID, never the app id, got \(id)")
		}

		// T15 UI-02 row 3: a failed read gives an unsaved id and an error line.
		do {
			let store = FakeKeychain()
			store.readErrors = [shared: locked]
			let log = captureLog()
			let id = identity(store).sharedUserId()
			debugLogSink = nil
			check(isUUID(id) && store.writes.isEmpty, "T15 UI-02 row 3: a failed read must return an unsaved UUID, got \(id), \(store.writes)")
			check(
				log().contains { $0.contains("[UserIdentity][error]") && $0.contains("-25308") },
				"T15 UI-02 row 3: a failed read must leave an error line naming the code, got \(log())"
			)
		}

		if failures.isEmpty {
			print("UserIdentity (UI-01, UI-02): 15/15 OK")
		} else {
			print("\(failures.count) check(s) failed:")
			for failure in failures {
				print("  - \(failure)")
			}
			exit(1)
		}
	}
}
