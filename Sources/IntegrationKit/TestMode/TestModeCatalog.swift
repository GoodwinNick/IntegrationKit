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
	static func product(id: String, hasTrial: Bool) -> PremiumProduct {
		PremiumProduct(
			id: id,
			localizedTitle: "UI test product",
			localizedPrice: "$9.99",
			price: Decimal(string: "9.99") ?? 0,
			currencyCode: "USD",
			subscriptionPeriod: PremiumPeriod(unit: .month, numberOfUnits: 1),
			introductoryOffer: hasTrial ? trial : nil
		)
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
