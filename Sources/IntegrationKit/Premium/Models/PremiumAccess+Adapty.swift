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
	///
	/// `isVerified` says whether this profile came from the network in this process. The delegate
	/// push passes `false` for the first one, which the SDK hands over straight from its own
	/// storage (AD-05 row 2).
	init(profile: AdaptyProfile, levels: Set<String>, isVerified: Bool = true) {
		guard let hit = profile.accessLevels.values.first(where: { levels.contains($0.id) && $0.isActive }) else {
			self.init(isActive: false, isVerified: isVerified)
			return
		}
		self.init(isActive: true, expiresAt: hit.isLifetime ? nil : hit.expiresAt, isVerified: isVerified)
	}
}
