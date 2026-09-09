//
//  PremiumProduct+StoreKit.swift
//  IntegrationKit
//

import Foundation
import StoreKit
import SwiftyStoreKit

extension PremiumProduct {
	/// Wraps an `SKProduct`.
	///
	/// The two paths do NOT differ in price accuracy, whatever this comment used to claim: Adapty
	/// has no price of its own on 2.10.x — `AdaptyPaywallProduct` holds an `SKProduct` and proxies
	/// `price`, `currencyCode`, `subscriptionPeriod` and `localizedPrice` straight to it, so for one
	/// product id both initializers produce the same number. What they differ in is availability:
	/// the Adapty path needs a loaded paywall, this one needs nothing but the id. That is the whole
	/// reason both exist (AD-03, note above the risk table).
	///
	/// `localizedPrice` is SwiftyStoreKit's formatter over `price` and `priceLocale`, and stays
	/// optional — a locale with no currency formatter gives no price, which is not an empty price.
	init(product: SKProduct) {
		self.init(
			id: product.productIdentifier,
			localizedTitle: product.localizedTitle,
			localizedPrice: product.localizedPrice,
			price: product.price as Decimal,
			currencyCode: product.priceLocale.currencyCode,
			subscriptionPeriod: product.subscriptionPeriod.map(PremiumPeriod.init(period:)),
			introductoryOffer: product.introductoryPrice.map(PremiumOffer.init(discount:))
		)
	}
}
