//
//  TestModeCatalog.swift
//  IntegrationKit
//
//  TM-05: the fake storefront. It exists without any flag asking for it — a test that buys nothing
//  needs prices just as much as one that buys, because a paywall without them draws placeholders and
//  every assertion on a button's text passes against an empty string (TM-05 row 7).
//

import Foundation

enum TestModeCatalog {

	/// Fixed values, so two runs of the same test compare the same strings. Anything derived from a
	/// clock or a locale here would make a green suite depend on the machine it ran on.
	///
	/// PAY01: period and price are derived from `id`, not fixed. A paywall that buckets its prices by
	/// period (a yearly label, a monthly label) needs the buckets to actually differ — every id seen
	/// so far, in this package's own checks and in every migrated app, spells its period out
	/// ("sub.month", "e_year_sub", "premium_week_trial"), so the id is what decides it.
	static func product(id: String, hasTrial: Bool) -> PremiumProduct {
		let period = Self.period(matching: id)
		let (price, localizedPrice) = Self.price(for: period.unit)
		return PremiumProduct(
			id: id,
			localizedTitle: "UI test product",
			localizedPrice: localizedPrice,
			price: price,
			currencyCode: "USD",
			subscriptionPeriod: period,
			introductoryOffer: hasTrial ? trial : nil
		)
	}

	private static func period(matching id: String) -> PremiumPeriod {
		let id = id.lowercased()
		if id.contains("year") { return PremiumPeriod(unit: .year, numberOfUnits: 1) }
		if id.contains("week") { return PremiumPeriod(unit: .week, numberOfUnits: 1) }
		// The pre-PAY01 default, and still the fallback for an id that names no period at all.
		return PremiumPeriod(unit: .month, numberOfUnits: 1)
	}

	private static func price(for unit: PremiumPeriod.Unit) -> (Decimal, String) {
		switch unit {
			case .year: return (Decimal(string: "59.99") ?? 0, "$59.99")
			case .week: return (Decimal(string: "2.99") ?? 0, "$2.99")
			default: return (Decimal(string: "9.99") ?? 0, "$9.99")
		}
	}

	/// `-storeHasTrial` is a property of the store's product, and it is not `-hasTrial`, which is a
	/// paywall value an app writes as `-paywallValue hasTrial=true`. Merging the two is forbidden by
	/// the user's decision of 2026-09-11 (TM-05 row 8).
	private static let trial = PremiumOffer(
		price: 0,
		localizedPrice: "$0.00",
		period: PremiumPeriod(unit: .week, numberOfUnits: 1),
		numberOfPeriods: 1,
		paymentMode: .freeTrial
	)
}
