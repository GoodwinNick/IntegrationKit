//
//  PremiumProduct+StoreKit.swift
//  IntegrationKit
//

import Foundation
import StoreKit
import SwiftyStoreKit

extension PremiumProduct {
	/// Wraps an `SKProduct`. This is the accurate source for a price: Adapty answers with what its
	/// dashboard last synced, the store answers with what the user will actually be charged, in
	/// their own storefront and currency. `localizedPrice` is SwiftyStoreKit's formatter over
	/// `price` and `priceLocale` — empty only when the locale has no currency formatter at all.
	init(product: SKProduct) {
		self.init(
			id: product.productIdentifier,
			localizedTitle: product.localizedTitle,
			localizedPrice: product.localizedPrice ?? "",
			price: product.price as Decimal,
			currencyCode: product.priceLocale.currencyCode,
			subscriptionPeriod: product.subscriptionPeriod.map(PremiumPeriod.init(period:)),
			introductoryOffer: product.introductoryPrice.map(PremiumOffer.init(discount:))
		)
	}
}
