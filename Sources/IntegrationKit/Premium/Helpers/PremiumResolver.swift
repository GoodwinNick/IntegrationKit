//
//  PremiumResolver.swift
//  IntegrationKit
//
//  PM-03: three candidates in, one state out. Pure — no clock, no storage, no side effects.
//

import Foundation

enum PremiumResolver {
	/// Adapty is the final authority when it can answer; Apple's receipt is the reserve when it
	/// stays silent. `apple == nil` means "receipt not checked", not "no access". `localPurchase`
	/// marks that a purchase or restore just went through on this device — a receipt of its own,
	/// held against a verified denial Adapty gave us before that purchase happened.
	static func resolve(adapty: PremiumAccess?, apple: ReceiptAnswer?, cached: PremiumState?, localPurchase: Bool = false, now: Date) -> PremiumState {
		let mark = localPurchase || (cached?.localPurchase ?? false)
		// A purchase or restore that just went through on this device is a receipt saying yes,
		// newer than anything we could check.
		let receipt = localPurchase ? ReceiptAnswer(isActive: true, expiresAt: apple?.expiresAt) : apple
		// ...and it must not be swallowed by a verified denial Adapty gave us before the purchase.
		let cache = localPurchase
			? cached.map { PremiumState(isPremium: $0.isPremium, source: $0.source, isVerified: false, expiresAt: $0.expiresAt, localPurchase: $0.localPurchase) }
			: cached

		// 1. Adapty confirmed — it wins and the mark is no longer needed. A grant counts even when it
		//    is unverified: the SDK's stored profile saying "premium" is still a yes, and doubt goes
		//    to the user.
		if let adapty {
			if adapty.isActive {
				return PremiumState(isPremium: true, source: .adapty, isVerified: adapty.isVerified, expiresAt: adapty.expiresAt, localPurchase: false)
			}
			// Adapty says no. That is final only when the answer was actually checked in this process
			// and no local purchase is outstanding. An UNVERIFIED denial is the profile the SDK
			// pushed out of its own storage on activation — a memory of the last launch, which must
			// not close access before the network has answered (AD-05 row 2); with the mark, Adapty
			// simply has not seen the purchase yet. Either way we fall through as if it stayed silent.
			if !mark, adapty.isVerified {
				return PremiumState(isPremium: false, source: .adapty, isVerified: true, expiresAt: adapty.expiresAt, localPurchase: false)
			}
		}
		// 2. The last thing we knew, still valid.
		if let cache, cache.isVerified || cache.isPremium, !cache.isExpired(at: now) {
			return PremiumState(isPremium: cache.isPremium, source: cache.source, isVerified: cache.isVerified, expiresAt: cache.expiresAt, localPurchase: mark)
		}
		// 3. Apple's receipt as the reserve — and the only thing that can close premium while the
		//    mark demotes Adapty, which is why it has to carry the expiry.
		if let receipt {
			let premium = receipt.isActive && !(receipt.expiresAt.map { $0 <= now } ?? false)
			return PremiumState(isPremium: premium, source: premium ? .apple : .none, isVerified: false, expiresAt: receipt.expiresAt, localPurchase: premium ? mark : false)
		}
		// 4. Nobody answered. Whatever reaches here is expired or was never premium, so the verdict
		//    is always "no premium" — the expiry is carried through so the caller can still see it.
		return PremiumState(isPremium: false, source: .none, isVerified: false, expiresAt: cached?.expiresAt, localPurchase: false)
	}
}
