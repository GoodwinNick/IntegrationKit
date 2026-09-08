//
//  PremiumOffer+StoreKit.swift
//  IntegrationKit
//

import Foundation
import StoreKit
import SwiftyStoreKit

extension PremiumOffer {
	/// Maps `SKProductDiscount` — the store's own introductory offer, which is what decides
	/// whether the paywall may say "free trial" for this particular user.
	init(discount: SKProductDiscount) {
		let paymentMode: PaymentMode
		switch discount.paymentMode {
			case .payAsYouGo:
				paymentMode = .payAsYouGo
			case .payUpFront:
				paymentMode = .payUpFront
			case .freeTrial:
				paymentMode = .freeTrial
			@unknown default:
				paymentMode = .unknown
		}
		self.init(
			price: discount.price as Decimal,
			localizedPrice: discount.localizedPrice,
			period: PremiumPeriod(period: discount.subscriptionPeriod),
			numberOfPeriods: discount.numberOfPeriods,
			paymentMode: paymentMode
		)
	}
}
