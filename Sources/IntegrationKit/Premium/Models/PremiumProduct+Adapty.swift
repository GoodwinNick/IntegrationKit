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
		// PM-07 row 17: `product.price` is just `skProduct.price` (`AdaptyProduct.swift:35-37`), which
		// can carry the same truncation StoreKit sometimes produces. `skProduct` itself — and so its
		// `priceFormatStyle` — is a real `StoreKit.Product` with no public initialiser, out of reach for
		// a harness that stubs `AdaptyPaywallProduct`; the corrected value is recovered instead from
		// `currencyCode` and the device's own current locale, the same locale StoreKit itself uses to
		// build `displayPrice`/`priceFormatStyle` (Apple docs: "a localized number suitable for
		// display").
		let formatStyle = product.currencyCode.map { Decimal.FormatStyle.Currency(code: $0, locale: .autoupdatingCurrent) }
		let introductoryOffer = product.subscriptionOffer.flatMap { offer in
			offer.offerType == .introductory ? PremiumOffer(offer: offer, formatStyle: formatStyle) : nil
		}
		self.init(
			id: product.vendorProductId,
			localizedTitle: product.localizedTitle,
			localizedPrice: product.localizedPrice,
			price: StorePrice.corrected(raw: product.price, displayPrice: product.localizedPrice, formatStyle: formatStyle),
			currencyCode: product.currencyCode,
			subscriptionPeriod: product.subscriptionPeriod.map(PremiumPeriod.init(period:)),
			introductoryOffer: introductoryOffer
		)
	}
}
