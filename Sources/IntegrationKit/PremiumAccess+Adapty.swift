//
//  PremiumAccess+Adapty.swift
//  IntegrationKit
//

import Adapty
import Foundation

extension PremiumAccess {
	/// Flattens an Adapty profile down to the one answer the premium logic needs.
	/// `levels` are the access level ids configured in the Adapty dashboard — the app names
	/// them, the library never assumes one. A lifetime level never expires.
	public init(profile: AdaptyProfile, levels: Set<String>) {
		guard let hit = profile.accessLevels.values.first(where: { levels.contains($0.id) && $0.isActive }) else {
			self.init(isActive: false)
			return
		}
		self.init(isActive: true, expiresAt: hit.isLifetime ? nil : hit.expiresAt)
	}
}
