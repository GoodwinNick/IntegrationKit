//
//  PremiumResolver.swift
//  IntegrationKit
//
//  PM-03: three candidates in, one state out. Pure — no clock, no storage, no side effects.
//

import Foundation

enum PremiumResolver {
	/// Adapty is the final authority; Apple's receipt is the reserve when Adapty stays silent.
	/// `apple == nil` means "receipt not checked", not "no access".
	static func resolve(adapty: PremiumAccess?, apple: Bool?, cached: PremiumState?, now: Date) -> PremiumState {
		// 1. Adapty answered — it wins, always, in both directions.
		if let adapty {
			return PremiumState(isPremium: adapty.isActive, source: .adapty, isVerified: true, expiresAt: adapty.expiresAt)
		}
		// 2. The last thing Adapty told us, still valid. Adapty is final in both directions:
		//    a verified revoke must not be undone by a stale Apple receipt. An unverified premium
		//    cache (a local purchase Adapty has not confirmed yet) is kept for the same reason —
		//    рішення 2026-09-07: «краще трохи доплатити за халявщика, ніж втратити према».
		if let cached, cached.isVerified || cached.isPremium, !cached.isExpired(at: now) {
			return cached
		}
		// 3. Apple receipt as the reserve.
		if let apple {
			return PremiumState(isPremium: apple, source: apple ? .apple : .none, isVerified: false, expiresAt: nil)
		}
		// 4. Nobody answered — keep what we had, but stop calling it verified.
		if let cached {
			let stillValid = cached.isPremium && !cached.isExpired(at: now)
			return PremiumState(
				isPremium: stillValid,
				source: stillValid ? cached.source : .none,
				isVerified: false,
				expiresAt: cached.expiresAt
			)
		}
		return .free
	}
}
