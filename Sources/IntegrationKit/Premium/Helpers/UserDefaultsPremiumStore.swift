//
//  UserDefaultsPremiumStore.swift
//  IntegrationKit
//

import Foundation

/// Default storage: the resolved state as JSON, the legacy flag as a plain Bool. An app that
/// keeps the flag somewhere of its own supplies its own `PremiumStateStoring` instead.
final class UserDefaultsPremiumStore: PremiumStateStoring {
	private let defaults: UserDefaults
	private let stateKey: String
	private let flagKey: String

	init(defaults: UserDefaults = .standard, stateKey: String = "premiumStateKey", flagKey: String = "premiumKey") {
		self.defaults = defaults
		self.stateKey = stateKey
		self.flagKey = flagKey
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
			// PM-04: the flag is written from Adapty's background queue too, and every observer
			// is a screen — the notification always goes out on the main queue.
			DispatchQueue.main.async {
				NotificationCenter.default.post(name: .premiumDidChange, object: nil)
			}
		}
	}
}
