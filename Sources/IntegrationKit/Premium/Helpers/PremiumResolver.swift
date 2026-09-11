//
//  PremiumResolver.swift
//  IntegrationKit
//
//  PM-03: three candidates in, one state out. Pure — no clock, no storage, no side effects.
//

import Foundation

enum PremiumResolver {
	/// How long the local-purchase mark lives. It covers the window in which Adapty has not yet seen
	/// a purchase made past it, and until 0.6.0 that window had no way to close except Adapty's own
	/// confirmation — which may never come.
	///
	/// Under the arbitration rule of 2026-09-11 the window is no longer a window: Adapty cannot take
	/// premium away at all, from anyone, mark or no mark. So the ageing decides nothing today — the
	/// mark is computed, carried and stored, and every verdict below would come out the same without
	/// it. It is kept rather than deleted because the one open question on that rule (a grant that
	/// arrives with no date can never be revoked) is cured by letting a denial through in exactly
	/// that case, and then the mark is again what protects a fresh purchase from it.
	static let markLifetime: TimeInterval = 7 * 24 * 3600

	/// Adapty hands premium out and never takes it back; Apple's receipt and the expiry date are
	/// what close access. `apple == nil` means "receipt not checked", not "no access".
	/// `localPurchase` marks that a purchase or restore just went through on this device — a receipt
	/// of its own, newer than the cached verdict it has to get past.
	static func resolve(adapty: PremiumAccess?, apple: ReceiptAnswer?, cached: PremiumState?, localPurchase: Bool = false, now: Date) -> PremiumState {
		// The mark carries its own birth date, and the date is written only when no live mark was
		// standing. Refreshing it on every event would let one repeating event — the same unfinished
		// transaction handed over by the payment queue on every launch — push the deadline out
		// forever, which is the hole this ageing exists to close. A mark with no date at all comes
		// from a cache written before 0.6.0: it counts as brand new, so an upgrade alone never takes
		// premium away from someone who has it.
		let carried = (cached?.localPurchase ?? false) ? (cached?.localPurchaseAt ?? now) : nil
		let carriedIsLive = carried.map { now.timeIntervalSince($0) < markLifetime } ?? false
		let markSince: Date? = carriedIsLive ? carried : (localPurchase ? now : nil)
		let mark = markSince != nil
		// A purchase or restore that just went through on this device is a receipt saying yes,
		// newer than anything we could check.
		let receipt = localPurchase ? ReceiptAnswer(isActive: true, expiresAt: apple?.expiresAt) : apple
		// ...and it must not be swallowed by the cached verdict that was written before the purchase.
		// Dropping `isVerified` is what makes rule 2 let go: a cached "no premium" only holds the
		// verdict because it was verified, and against a payment that just cleared it is simply old.
		//
		// The expiry is refreshed from Adapty's answer in the same breath (PM-03 row 23, user's rule:
		// the expiry mirrors the profile). It matters only on a denial — a grant returns from rule 1
		// long before this is read — and it is what turns "Adapty never revokes" into something other
		// than "premium is forever": the denial still decides nothing, the date it arrived with does.
		// Adapty having no date at all leaves the cache's own, which is the honest answer and also the
		// hole in row 22.
		let cache = cached.map {
			PremiumState(
				isPremium: $0.isPremium,
				source: $0.source,
				isVerified: localPurchase ? false : $0.isVerified,
				expiresAt: adapty?.expiresAt ?? $0.expiresAt,
				localPurchase: $0.localPurchase,
				localPurchaseAt: $0.localPurchaseAt
			)
		}

		// 1. Adapty grants, and only grants (user's decision, 2026-09-11: "Adapty is only there to
		//    hand out a custom premium, not to remove an existing one"). A grant counts even when it
		//    is unverified — the SDK's stored profile saying "premium" is still a yes, and doubt goes
		//    to the user. A denial is not an answer at all: `isActive == false` falls through exactly
		//    like silence, verified or not, so no branch below can tell the two apart.
		//
		//    What removes premium instead: the expiry date (rule 2), the receipt (rule 3) and
		//    "nobody answered" (rule 4). A premium the store knows nothing about is one the dashboard
		//    handed out, and Adapty writes an end date on those — so the date takes it back.
		if let adapty, adapty.isActive {
			return PremiumState(isPremium: true, source: .adapty, isVerified: adapty.isVerified, expiresAt: adapty.expiresAt, localPurchase: false)
		}
		// 2. The last thing we knew, still valid.
		if let cache, cache.isVerified || cache.isPremium, !cache.isExpired(at: now) {
			return PremiumState(isPremium: cache.isPremium, source: cache.source, isVerified: cache.isVerified, expiresAt: cache.expiresAt, localPurchase: mark, localPurchaseAt: markSince)
		}
		// 3. Apple's receipt as the reserve, and — now that Adapty never denies — the only source that
		//    can still answer "no". It only gets asked once the cache has stopped holding, so a
		//    premium whose expiry is nil never reaches this branch at all. Hence the expiry matters.
		if let receipt {
			let premium = receipt.isActive && !(receipt.expiresAt.map { $0 <= now } ?? false)
			return PremiumState(isPremium: premium, source: premium ? .apple : .none, isVerified: false, expiresAt: receipt.expiresAt, localPurchase: premium ? mark : false, localPurchaseAt: premium ? markSince : nil)
		}
		// 4. Nobody answered. Whatever reaches here is expired or was never premium, so the verdict
		//    is always "no premium" — the expiry is carried through so the caller can still see it.
		return PremiumState(isPremium: false, source: .none, isVerified: false, expiresAt: cache?.expiresAt, localPurchase: false)
	}
}
