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

		// 2. Adapty hands premium out and never takes it back (user's decision, 2026-09-11). A denial
		//    is not an answer at all, so the cached premium stands. The silent run on the same fixture
		//    is the half that carries the proof: equal verdicts mean the denial was ignored, not that
		//    the resolver never reached it.
		let unverified = PremiumState(isPremium: true, source: .apple, isVerified: false)
		let againstDenial = PremiumResolver.resolve(adapty: PremiumAccess(isActive: false), apple: ReceiptAnswer(isActive: true, expiresAt: nil), cached: unverified, now: now)
		assert(againstDenial.isPremium, "PM-03 rule 1: a verified Adapty denial must not remove premium, expected the cached premium to stand, got \(againstDenial)")
		assert(againstDenial.source == .apple, "PM-03 rule 1: the verdict comes from the cache, not from the denial, expected source .apple, got \(againstDenial.source)")
		let againstSilence = PremiumResolver.resolve(adapty: nil, apple: ReceiptAnswer(isActive: true, expiresAt: nil), cached: unverified, now: now)
		assert(againstDenial == againstSilence, "PM-03 rule 1: a denial must resolve exactly like silence, expected \(againstSilence), got \(againstDenial)")

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

		// 9. PM-03 row 18 (AD-05 row 2), now pointed the other way. Provenance used to be the gate that
		//    let a network denial through and held a disk-cached one back; since 2026-09-11 neither gets
		//    through, so what this case guards is that the two are still indistinguishable. The verified
		//    run is the one that would catch the old branch coming back for network answers only.
		let unverifiedCache = PremiumState(isPremium: true, source: .apple, isVerified: false)
		let silent = PremiumResolver.resolve(adapty: nil, apple: nil, cached: unverifiedCache, now: now)
		let diskDenial = PremiumResolver.resolve(adapty: PremiumAccess(isActive: false, isVerified: false), apple: nil, cached: unverifiedCache, now: now)
		assert(diskDenial == silent, "PM-03 row 18: an unverified Adapty denial must resolve exactly like silence, expected \(silent), got \(diskDenial)")
		let networkDenial = PremiumResolver.resolve(adapty: PremiumAccess(isActive: false), apple: nil, cached: unverifiedCache, now: now)
		assert(networkDenial == silent, "PM-03 row 18: a verified denial must resolve like silence too, expected \(silent), got \(networkDenial)")
		assert(networkDenial.isPremium && networkDenial.source == .apple, "PM-03 row 18: the cached premium stands against both, expected premium from .apple, got \(networkDenial)")

		// 10. PM-03 row 8, the receipt half. The `<=` rule is written twice, in two files and two
		//     shapes: `PremiumState.isExpired(at:)` guards the cache branch, and branch 3 compares the
		//     receipt's own date inline. Case 7 above pins the first. Nothing pinned the second — and
		//     since 2026-09-11 those two comparisons are the only things left in the whole resolver
		//     that can close access at all, so a drift to `<` there would go unnoticed.
		let receiptExpiry = now + hour
		let liveReceipt = ReceiptAnswer(isActive: true, expiresAt: receiptExpiry)
		let atReceiptBoundary = PremiumResolver.resolve(adapty: nil, apple: liveReceipt, cached: nil, now: receiptExpiry)
		assert(atReceiptBoundary.isPremium == false, "PM-03 row 8: at the receipt's expiresAt == now premium is already gone, expected isPremium false, got \(atReceiptBoundary.isPremium)")
		assert(atReceiptBoundary.source == .none, "PM-03 row 8: a receipt that closed access is not a source of premium, expected source .none, got \(atReceiptBoundary.source)")
		assert(atReceiptBoundary.expiresAt == receiptExpiry, "PM-03 row 8: the receipt's expiry is carried through even when it closed access, expected \(receiptExpiry), got \(String(describing: atReceiptBoundary.expiresAt))")
		let beforeReceiptBoundary = PremiumResolver.resolve(adapty: nil, apple: liveReceipt, cached: nil, now: receiptExpiry - 0.001)
		assert(beforeReceiptBoundary.isPremium, "PM-03 row 8: one millisecond earlier the same receipt still grants, expected isPremium true, got \(beforeReceiptBoundary.isPremium)")

		// 11. PM-03 row 23: the expiry mirrors the Adapty profile, on a denial too. A level that has
		//     ended still carries a real date — a refund moves it to the refund date — and until
		//     2026-09-11 the mapping dropped it, so a cache written while the level was live went on
		//     granting off its own stale date. The rule that Adapty never revokes is untouched: the
		//     denial closes nothing by itself, the date it brought does, and only once that is past.
		let staleCache = PremiumState(isPremium: true, source: .adapty, isVerified: true, expiresAt: now + 10 * hour)
		let endedLevel = PremiumResolver.resolve(adapty: PremiumAccess(isActive: false, expiresAt: now - hour), apple: nil, cached: staleCache, now: now)
		assert(endedLevel.isPremium == false, "PM-03 row 23: the profile's own expiry, already past, must close access, got \(endedLevel.isPremium)")
		assert(endedLevel.expiresAt == now - hour, "PM-03 row 23: the verdict must carry Adapty's date, not the cache's, expected \(now - hour), got \(String(describing: endedLevel.expiresAt))")
		// The half that proves it was the date and not something else: the very same denial, dated
		// ahead, changes nothing but the expiry. Without this run the assert above would be green off
		// ordinary cache expiry, which has nothing to do with the profile.
		let livingLevel = PremiumResolver.resolve(adapty: PremiumAccess(isActive: false, expiresAt: now + hour), apple: nil, cached: staleCache, now: now)
		assert(
			livingLevel == PremiumState(isPremium: true, source: .adapty, isVerified: true, expiresAt: now + hour),
			"PM-03 row 23: a denial dated ahead must move the expiry and nothing else, got \(livingLevel)"
		)

		print("PremiumResolver: 11/11 OK")
	}
}
