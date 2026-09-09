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
		let revoked = PremiumResolver.resolve(adapty: PremiumAccess(isActive: false), apple: ReceiptAnswer(isActive: true, expiresAt: nil), cached: unverified, now: now)
		assert(!revoked.isPremium, "PM-03 rule 1: Adapty inactive must revoke, even against a receipt saying true")

		// 3. THE rule (2026-09-07): an unverified purchase is held until Adapty speaks — a `false`
		//    receipt does not take it away.
		let kept = PremiumResolver.resolve(adapty: nil, apple: ReceiptAnswer(isActive: false, expiresAt: nil), cached: unverified, now: now)
		assert(kept.isPremium && !kept.isVerified, "PM-03 rule 2: a false receipt must not drop an unverified purchase")

		// 4. Expired cache, receipt says yes — premium comes back unverified, without an expiry.
		let expired = PremiumState(isPremium: true, source: .adapty, isVerified: true, expiresAt: now - hour)
		let fromReceipt = PremiumResolver.resolve(adapty: nil, apple: ReceiptAnswer(isActive: true, expiresAt: nil), cached: expired, now: now)
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

		// 8. PM-03 row 6, the provenance half (AD-05 row 2): a grant the SDK pushed straight out of its
		//    own storage on activation is still a grant. It is recorded as unverified so a later silence
		//    cannot be mistaken for a network confirmation — but access opens either way, because doubt
		//    goes to the user.
		let diskGrant = PremiumResolver.resolve(adapty: PremiumAccess(isActive: true, expiresAt: now + hour, isVerified: false), apple: nil, cached: nil, now: now)
		assert(diskGrant.isPremium, "PM-03 row 6: an unverified Adapty grant must still grant, expected isPremium true, got \(diskGrant.isPremium)")
		assert(diskGrant.isVerified == false, "PM-03 row 6: the verdict must carry the answer's own provenance, expected isVerified false, got \(diskGrant.isVerified)")
		assert(diskGrant.source == .adapty, "PM-03 row 6: expected source .adapty, got \(diskGrant.source)")
		assert(diskGrant.expiresAt == now + hour, "PM-03 row 6: the profile's expiry must come through, expected \(now + hour), got \(String(describing: diskGrant.expiresAt))")

		// 9. PM-03 row 18 (AD-05 row 2, the other half): the same disk-cached profile saying NO is a
		//    memory of the last launch, not a check. It must not close access before the network has
		//    answered — the resolver falls through as if Adapty had stayed silent. The verified denial
		//    right after it is the contrast that proves `isVerified` is the field doing the deciding.
		let unverifiedCache = PremiumState(isPremium: true, source: .apple, isVerified: false)
		let diskDenial = PremiumResolver.resolve(adapty: PremiumAccess(isActive: false, isVerified: false), apple: nil, cached: unverifiedCache, now: now)
		assert(diskDenial.isPremium, "PM-03 row 18: an unverified Adapty denial must not close access, expected the cached premium to stand, got \(diskDenial)")
		assert(diskDenial.source == .apple, "PM-03 row 18: the verdict must come from the cache, not from the denial, expected source .apple, got \(diskDenial.source)")
		let networkDenial = PremiumResolver.resolve(adapty: PremiumAccess(isActive: false), apple: nil, cached: unverifiedCache, now: now)
		assert(networkDenial.isPremium == false, "PM-03 row 18: the very same denial, verified, must revoke — expected isPremium false, got \(networkDenial.isPremium)")
		assert(networkDenial.source == .adapty, "PM-03 row 18: a verified denial is Adapty's own verdict, expected source .adapty, got \(networkDenial.source)")

		print("PremiumResolver: 9/9 OK")
	}
}
