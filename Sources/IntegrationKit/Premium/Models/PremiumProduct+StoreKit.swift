//
//  PremiumProduct+StoreKit.swift
//  IntegrationKit
//

import Foundation
import StoreKit

extension PremiumProduct {
	/// Wraps a `StoreKit.Product`.
	///
	/// PM-07: unlike Adapty's own product copy, this direct query never checks
	/// `isEligibleForIntroOffer` — `introductoryOffer` comes back whenever App Store Connect has
	/// one configured, whether or not this particular user is still eligible for it. See
	/// storekit-intro-offer-eligibility.
	init(product: Product) {
		self.init(
			id: product.id,
			localizedTitle: product.displayName,
			localizedPrice: product.displayPrice,
			price: StorePrice.corrected(raw: product.price, displayPrice: product.displayPrice, formatStyle: product.priceFormatStyle),
			currencyCode: product.priceFormatStyle.currencyCode,
			subscriptionPeriod: product.subscription.map { PremiumPeriod(period: $0.subscriptionPeriod) },
			introductoryOffer: product.subscription?.introductoryOffer.map { PremiumOffer(offer: $0, formatStyle: product.priceFormatStyle) }
		)
	}
}
