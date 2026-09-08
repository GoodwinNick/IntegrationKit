//
//  PremiumResolverCheck.swift
//  IntegrationKit
//
//  PM-03 rules 1-4 plus risk rows 4 and 8. No test framework: the resolver is pure, so a script is
//  enough — every candidate is handed in by value, `now` included, so nothing here waits on a clock.
//  Run:  ./Checks/premium-resolver-check.sh
//

import Foundation

@main
enum PremiumResolverCheck {
	static func main() {
		let now = Date()
		let hour: TimeInterval = 3600

		// 1. Adapty active — verified premium, whatever the cache said.
		let fromAdapty = PremiumResolver.resolve(adapty: PremiumAccess(isActive: true, expiresAt: now + hour), apple: nil, cached: nil, now: now)
		assert(fromAdapty.isPremium && fromAdapty.isVerified && fromAdapty.source == .adapty, "PM-03 rule 1: Adapty active must grant verified premium")

		// 2. Adapty inactive — takes premium away even from an unverified local purchase.
		let unverified = PremiumState(isPremium: true, source: .apple, isVerified: false)
		let revoked = PremiumResolver.resolve(adapty: PremiumAccess(isActive: false), apple: true, cached: unverified, now: now)
		assert(!revoked.isPremium, "PM-03 rule 1: Adapty inactive must revoke, even against a receipt saying true")

		// 3. THE rule (2026-09-07): an unverified purchase is held until Adapty speaks — a `false`
		//    receipt does not take it away.
		let kept = PremiumResolver.resolve(adapty: nil, apple: false, cached: unverified, now: now)
		assert(kept.isPremium && !kept.isVerified, "PM-03 rule 2: a false receipt must not drop an unverified purchase")

		// 4. Expired cache, receipt says yes — premium comes back unverified, without an expiry.
		let expired = PremiumState(isPremium: true, source: .adapty, isVerified: true, expiresAt: now - hour)
		let fromReceipt = PremiumResolver.resolve(adapty: nil, apple: true, cached: expired, now: now)
		assert(fromReceipt.isPremium && !fromReceipt.isVerified && fromReceipt.source == .apple && fromReceipt.expiresAt == nil, "PM-03 rule 3: receipt true after an expired cache gives unverified premium")

		// 5. Everyone silent, nothing cached — free.
		assert(PremiumResolver.resolve(adapty: nil, apple: nil, cached: nil, now: now) == .free, "PM-03 rule 4: no sources, no cache means free")

		// 6. PM-03 row 4: an unverified cache that has expired, and nobody left to ask. Premium goes
		//    away — but the result is NOT the `.free` singleton: branch 4 carries `cached.expiresAt`
		//    through, so every field has to be checked one by one rather than compared to `.free`.
		let staleUnverified = PremiumState(isPremium: true, source: .apple, isVerified: false, expiresAt: now - hour)
		let lapsed = PremiumResolver.resolve(adapty: nil, apple: nil, cached: staleUnverified, now: now)
		assert(lapsed.isPremium == false, "PM-03 row 4: an expired unverified cache must lose premium, expected isPremium false, got \(lapsed.isPremium)")
		assert(lapsed.source == .none, "PM-03 row 4: expected source .none, got \(lapsed.source)")
		assert(lapsed.isVerified == false, "PM-03 row 4: nobody answered — expected isVerified false, got \(lapsed.isVerified)")
		assert(lapsed.expiresAt == staleUnverified.expiresAt, "PM-03 row 4: branch 4 carries the cached expiry through, expected \(String(describing: staleUnverified.expiresAt)), got \(String(describing: lapsed.expiresAt))")
		assert(lapsed != .free, "PM-03 row 4: the result keeps its expiry, so it is not the .free singleton, got \(lapsed)")

		// 7. PM-03 row 8: the boundary tick. `isExpired(at:)` compares with `<=`, so at exactly
		//    `expiresAt == now` the cache is already expired. Deterministic for the `now` handed in —
		//    which is the whole recognised limit: the package trusts the clock it is given.
		let boundaryExpiry = now + hour
		let boundaryCache = PremiumState(isPremium: true, source: .adapty, isVerified: true, expiresAt: boundaryExpiry)
		let atBoundary = PremiumResolver.resolve(adapty: nil, apple: nil, cached: boundaryCache, now: boundaryExpiry)
		assert(atBoundary.isPremium == false, "PM-03 row 8: at expiresAt == now the cache is expired, expected isPremium false, got \(atBoundary.isPremium)")
		assert(atBoundary.source == .none, "PM-03 row 8: expected source .none at the boundary, got \(atBoundary.source)")
		assert(atBoundary.isVerified == false, "PM-03 row 8: expected isVerified false at the boundary, got \(atBoundary.isVerified)")
		assert(atBoundary.expiresAt == boundaryExpiry, "PM-03 row 8: the expiry is carried through, expected \(boundaryExpiry), got \(String(describing: atBoundary.expiresAt))")
		let beforeBoundary = PremiumResolver.resolve(adapty: nil, apple: nil, cached: boundaryCache, now: boundaryExpiry - 0.001)
		assert(beforeBoundary == boundaryCache, "PM-03 row 8: one millisecond earlier the cache is still valid and handed back unchanged, expected \(boundaryCache), got \(beforeBoundary)")

		print("PremiumResolver: 7/7 OK")
	}
}
