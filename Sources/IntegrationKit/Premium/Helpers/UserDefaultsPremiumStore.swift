//
//  UserDefaultsPremiumStore.swift
//  IntegrationKit
//

import Foundation

/// Default storage: the resolved state as JSON, the legacy flag as a plain Bool. An app that
/// keeps the flag somewhere of its own supplies its own `PremiumStateStoring` instead.
final class UserDefaultsPremiumStore: PremiumStateStoring {
	/// Named once, because a test run's leftovers are wiped by these names too (TM-08).
	static let defaultStateKey = "premiumStateKey"
	static let defaultFlagKey = "premiumKey"
	static let defaultLevelsKey = "premiumLevelsKey"

	private let defaults: UserDefaults
	private let stateKey: String
	private let flagKey: String
	private let levelsKey = defaultLevelsKey

	init(defaults: UserDefaults = .standard, stateKey: String = defaultStateKey, flagKey: String = defaultFlagKey) {
		self.defaults = defaults
		self.stateKey = stateKey
		self.flagKey = flagKey
	}

	/// PM-10 row 16: an unreadable payload is "no levels" — every level closed, the general verdict
	/// untouched. Empty removes the key, so an app without a map never finds one on disk.
	var levels: [String: PremiumState] {
		get {
			defaults.data(forKey: levelsKey)
				.flatMap { try? JSONDecoder().decode([String: PremiumState].self, from: $0) } ?? [:]
		}
		set {
			defaults.set(newValue.isEmpty ? nil : try? JSONEncoder().encode(newValue), forKey: levelsKey)
		}
	}

	var cached: PremiumState? {
		get {
			defaults.data(forKey: stateKey)
				.flatMap { try? JSONDecoder().decode(PremiumState.self, from: $0) }
		}
		set {
			let data = try? JSONEncoder().encode(newValue)
			defaults.set(data, forKey: stateKey)
		}
	}

	var premium: Bool {
		get { defaults.bool(forKey: flagKey) }
		set {
			guard defaults.bool(forKey: flagKey) != newValue else { return }
			defaults.set(newValue, forKey: flagKey)
			// PM-06: the flag is written from Adapty's background queue too, and every observer
			// is a screen — the notification always goes out on the main queue.
			DispatchQueue.main.async {
				NotificationCenter.default.post(name: .premiumDidChange, object: nil)
			}
		}
	}
}
