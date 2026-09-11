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
		let ours = profile.accessLevels.values.filter { levels.contains($0.id) }
		// PM-03 row 23, user's rule 2026-09-11: "головне щоб ексірейшн оновлювався разом із профіля
		// адапті". So the date is read off the level whether it is still live or already over — a level
		// that ended keeps a real `expiresAt`, and a refund moves it to the refund date. Dropping it
		// here used to leave a cache written while the level was live granting off its own stale date,
		// with nobody left to say otherwise.
		//
		// Among ended levels the latest date wins, and a dated level beats a dateless one: `values` has
		// no order worth relying on, and of the arbitrary choices this is the one that errs toward the
		// user. Still `nil` for a lifetime level — there the absence IS the answer (row 22).
		guard let hit = ours.first(where: { $0.isActive })
			?? ours.max(by: { ($0.expiresAt ?? .distantPast) < ($1.expiresAt ?? .distantPast) })
		else {
			self.init(isActive: false, isVerified: isVerified)
			return
		}
		self.init(isActive: hit.isActive, expiresAt: hit.isLifetime ? nil : hit.expiresAt, isVerified: isVerified)
	}
}
