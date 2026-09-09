//
//  PremiumOffer+Adapty.swift
//  IntegrationKit
//

import Adapty
import Foundation

extension PremiumOffer {
	/// Maps `AdaptySubscriptionOffer` (Adapty 4.1.3, what 2.10.x's `AdaptyProductDiscount` became).
	/// `localizedPrice` is optional on the Adapty side too — it is `nil` only when the store locale
	/// has no formatter, so it stays optional here instead of being faked with a raw number.
	///
	/// The offer's KIND is not checked here: `PremiumProduct+Adapty.swift` decides which offers reach
	/// this initialiser at all, because `PremiumOffer` describes one shape of discount and knows
	/// nothing about which of Apple's three kinds produced it (AD-03).
	init(offer: AdaptySubscriptionOffer) {
		let paymentMode: PaymentMode
		switch offer.paymentMode {
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
			price: offer.price,
			localizedPrice: offer.localizedPrice,
			period: PremiumPeriod(period: offer.subscriptionPeriod),
			numberOfPeriods: offer.numberOfPeriods,
			paymentMode: paymentMode
		)
	}
}
