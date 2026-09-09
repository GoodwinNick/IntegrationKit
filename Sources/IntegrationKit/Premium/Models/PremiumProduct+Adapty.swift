//
//  PremiumProduct+Adapty.swift
//  IntegrationKit
//

import Adapty
import Foundation

extension PremiumProduct {
	/// Wraps an `AdaptyPaywallProduct` (Adapty 4.1.3) so the app never imports Adapty or StoreKit to
	/// show a price. `localizedPrice` is optional upstream and stays optional here: "no formatted
	/// price" is not the same value as "an empty price", and only the caller can decide what to draw
	/// for it.
	///
	/// AD-03: the introductory offer is filtered by hand now. 2.10.x had a dedicated
	/// `introductoryDiscount` field, so whatever came out of it WAS the introductory offer. 4.1.3 has
	/// one `subscriptionOffer` that carries any of three kinds — introductory, promotional or win-back
	/// — and `AdaptySubscriptionOfferType` is a `RawRepresentable` struct rather than an enum, so
	/// nothing forces this check to exist. Skipping it would show "3 days free" on a paywall to a user
	/// who is not eligible for a trial and would be charged the full price on tap.
	init(product: AdaptyPaywallProduct) {
		let introductoryOffer = product.subscriptionOffer.flatMap { offer in
			offer.offerType == .introductory ? PremiumOffer(offer: offer) : nil
		}
		self.init(
			id: product.vendorProductId,
			localizedTitle: product.localizedTitle,
			localizedPrice: product.localizedPrice,
			price: product.price,
			currencyCode: product.currencyCode,
			subscriptionPeriod: product.subscriptionPeriod.map(PremiumPeriod.init(period:)),
			introductoryOffer: introductoryOffer
		)
	}
}
