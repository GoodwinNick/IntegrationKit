//
//  PremiumOffer+StoreKit.swift
//  IntegrationKit
//

import Foundation
import StoreKit

extension PremiumOffer {
	/// Maps `Product.SubscriptionOffer` — the store's own introductory offer, which is what decides
	/// whether the paywall may say "free trial" for this particular product.
	init(offer: Product.SubscriptionOffer) {
		let paymentMode: PaymentMode
		switch offer.paymentMode {
			case .payAsYouGo:
				paymentMode = .payAsYouGo
			case .payUpFront:
				paymentMode = .payUpFront
			case .freeTrial:
				paymentMode = .freeTrial
			default:
				paymentMode = .unknown
		}
		self.init(
			price: offer.price,
			localizedPrice: offer.displayPrice,
			period: PremiumPeriod(period: offer.period),
			numberOfPeriods: offer.periodCount,
			paymentMode: paymentMode
		)
	}
}
