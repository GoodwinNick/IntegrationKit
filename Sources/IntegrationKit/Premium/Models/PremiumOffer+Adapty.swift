//
//  PremiumOffer+Adapty.swift
//  IntegrationKit
//

import Adapty
import Foundation

extension PremiumOffer {
	/// Maps `AdaptyProductDiscount` (Adapty 2.10.x). `localizedPrice` is optional on the Adapty
	/// side too — it is `nil` only when the store locale has no formatter, so it stays optional
	/// here instead of being faked with a raw number.
	init(discount: AdaptyProductDiscount) {
		let paymentMode: PaymentMode
		switch discount.paymentMode {
			case .payAsYouGo:
				paymentMode = .payAsYouGo
			case .payUpFront:
				paymentMode = .payUpFront
			case .freeTrial:
				paymentMode = .freeTrial
			case .unknown:
				paymentMode = .unknown
		}
		self.init(
			price: discount.price,
			localizedPrice: discount.localizedPrice,
			period: PremiumPeriod(period: discount.subscriptionPeriod),
			numberOfPeriods: discount.numberOfPeriods,
			paymentMode: paymentMode
		)
	}
}
