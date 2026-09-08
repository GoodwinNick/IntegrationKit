//
//  PremiumResolverCheck.swift
//  IntegrationKit
//
//  PM-03 in five asserts. No test framework: the resolver is pure, so a script is enough.
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

		print("PremiumResolver: 5/5 OK")
	}
}
