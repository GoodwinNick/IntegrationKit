//
//  PremiumOffer+StoreKit.swift
//  IntegrationKit
//

import Foundation
import StoreKit

extension PremiumOffer {
	/// Maps `Product.SubscriptionOffer` — the store's own introductory offer, which is what decides
	/// whether the paywall may say "free trial" for this particular product.
	///
	/// `formatStyle` is the parent product's `priceFormatStyle` — an offer has no formatter of its
	/// own, but App Store Connect guarantees it shares its product's currency and locale (PM-07 row 17).
	init(offer: Product.SubscriptionOffer, formatStyle: Decimal.FormatStyle.Currency) {
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
			price: StorePrice.corrected(raw: offer.price, displayPrice: offer.displayPrice, formatStyle: formatStyle),
			localizedPrice: offer.displayPrice,
			period: PremiumPeriod(period: offer.period),
			numberOfPeriods: offer.periodCount,
			paymentMode: paymentMode
		)
	}
}
