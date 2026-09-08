//
//  PremiumProduct+Adapty.swift
//  IntegrationKit
//

import Adapty
import Foundation

extension PremiumProduct {
	/// Wraps an `AdaptyPaywallProduct` (Adapty 2.10.x, all fields inherited from the
	/// `AdaptyProduct` protocol) so the app never imports Adapty or StoreKit to show a price.
	/// `localizedPrice` is optional upstream — an empty string here means the store gave no
	/// formatted price, which is a paywall-side problem, not a missing product.
	init(product: AdaptyPaywallProduct) {
		self.init(
			id: product.vendorProductId,
			localizedTitle: product.localizedTitle,
			localizedPrice: product.localizedPrice ?? "",
			price: product.price,
			currencyCode: product.currencyCode,
			subscriptionPeriod: product.subscriptionPeriod.map(PremiumPeriod.init(period:)),
			introductoryOffer: product.introductoryDiscount.map(PremiumOffer.init(discount:))
		)
	}
}
