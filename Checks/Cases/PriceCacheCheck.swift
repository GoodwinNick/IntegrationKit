//
//  PriceCacheCheck.swift
//  IntegrationKit
//
//  PM-07 rows 14-16, the three new rows Asana 1218522745188504 added for the cross-session price
//  cache. `PriceCache` is a pure actor over `PremiumProduct` and `UserDefaults` — no StoreKit, no
//  Adapty, no `PremiumService` needed to exercise its own merge/lookup contract.
//  Run:  ./Checks/price-cache-check.sh
//

import Foundation

@main
enum PriceCacheCheck {
	/// A fresh, throwaway `UserDefaults` suite per case — the same isolation `TestModeCheck.swift`
	/// settled on, so a case's cache can never read another case's write.
	static func isolatedCache() -> PriceCache {
		PriceCache(defaults: UserDefaults(suiteName: UUID().uuidString)!)
	}

	static func product(id: String, price: Decimal, offer: PremiumOffer? = nil) -> PremiumProduct {
		PremiumProduct(
			id: id,
			localizedTitle: id,
			localizedPrice: "$\(price)",
			price: price,
			currencyCode: "USD",
			subscriptionPeriod: PremiumPeriod(unit: .year, numberOfUnits: 1),
			introductoryOffer: offer
		)
	}

	@discardableResult
	static func wait(_ seconds: TimeInterval = 2, for condition: () -> Bool) -> Bool {
		let deadline = Date().addingTimeInterval(seconds)
		while Date() < deadline {
			if condition() { return true }
			RunLoop.current.run(until: Date().addingTimeInterval(0.005))
		}
		return condition()
	}

	static func main() {
		// 1. PM-07 row 14: an id the store answers about once, then stays silent about on a later
		//    call — `cached(ids:)` must still hand back that earlier answer, and must not fabricate
		//    one for an id it never saw at all.
		let row14Cache = isolatedCache()
		let weekV1 = product(id: "week.sub", price: 4.99)
		var warmed: [String: PremiumProduct]?
		Task { warmed = await row14Cache.merge(fresh: ["week.sub": weekV1]) }
		assert(wait { warmed != nil }, "row 14: the warm-up merge must call back")
		assert(warmed?["week.sub"] == weekV1, "row 14: the warm-up merge must hand back what it was given, got \(String(describing: warmed))")

		var fromCache: [String: PremiumProduct]?
		Task { fromCache = await row14Cache.cached(ids: ["week.sub", "year.sub"]) }
		assert(wait { fromCache != nil }, "row 14: cached(ids:) must call back")
		assert(fromCache?["week.sub"] == weekV1, "row 14: an id the store went silent about must still answer from the previous session's price, got \(String(describing: fromCache?["week.sub"]))")
		assert(fromCache?["year.sub"] == nil, "row 14: an id the cache never saw must be absent, not fabricated, got \(String(describing: fromCache?["year.sub"]))")

		// 2. PM-07 row 15: `introductoryOffer` is the one field `merge` does not overwrite with a
		//    fresh `nil` — price, currency and period stay fresh regardless.
		let row15Cache = isolatedCache()
		let offer = PremiumOffer(price: 0, localizedPrice: "Free", period: PremiumPeriod(unit: .week, numberOfUnits: 1), numberOfPeriods: 1, paymentMode: .freeTrial)
		let yearWithOffer = product(id: "year.sub", price: 29.99, offer: offer)
		var firstMerge: [String: PremiumProduct]?
		Task { firstMerge = await row15Cache.merge(fresh: ["year.sub": yearWithOffer]) }
		assert(wait { firstMerge != nil }, "row 15: the first merge must call back")
		assert(firstMerge?["year.sub"]?.introductoryOffer == offer, "row 15: the first merge must carry the offer StoreKit actually gave, got \(String(describing: firstMerge?["year.sub"]?.introductoryOffer))")

		let yearNoOfferFresh = product(id: "year.sub", price: 34.99)
		var secondMerge: [String: PremiumProduct]?
		Task { secondMerge = await row15Cache.merge(fresh: ["year.sub": yearNoOfferFresh]) }
		assert(wait { secondMerge != nil }, "row 15: the second merge must call back")
		assert(secondMerge?["year.sub"]?.introductoryOffer == offer, "row 15: a fresh nil offer must not overwrite the one already cached, got \(String(describing: secondMerge?["year.sub"]?.introductoryOffer))")
		assert(secondMerge?["year.sub"]?.price == 34.99, "row 15: the price itself must stay fresh regardless of the offer exception, got \(String(describing: secondMerge?["year.sub"]?.price))")

		// 3. PM-07 row 16: two concurrent `merge` calls for the same id must not corrupt the cache or
		//    lose either write — the actor serializes them, so the final state is exactly one of the
		//    two answers, never a torn mix and never neither.
		let row16Cache = isolatedCache()
		let productA = product(id: "month.sub", price: 9.99)
		let productB = product(id: "month.sub", price: 12.99)
		var raceDone = 0
		Task {
			_ = await row16Cache.merge(fresh: ["month.sub": productA])
			raceDone += 1
		}
		Task {
			_ = await row16Cache.merge(fresh: ["month.sub": productB])
			raceDone += 1
		}
		assert(wait { raceDone == 2 }, "row 16: both concurrent merges must complete, got \(raceDone)")
		var raceResult: [String: PremiumProduct]?
		Task { raceResult = await row16Cache.cached(ids: ["month.sub"]) }
		assert(wait { raceResult != nil }, "row 16: the post-race lookup must call back")
		assert(
			raceResult?["month.sub"] == productA || raceResult?["month.sub"] == productB,
			"row 16: the final state must be exactly one racer's answer, not a mix or a loss, got \(String(describing: raceResult?["month.sub"]))"
		)

		print("PriceCache (PM-07 rows 14-16): 3/3 OK")
	}
}
