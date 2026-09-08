//
//  PremiumProduct.swift
//  IntegrationKit
//

import Foundation

/// A purchasable product, as the facade hands it out — wraps an Adapty product so the app
/// never needs to import Adapty or StoreKit just to show a price.
public struct PremiumProduct: Equatable, Sendable {
	public let id: String
	public let localizedTitle: String
	public let localizedPrice: String
	public let price: Decimal
	public let currencyCode: String?
	public let subscriptionPeriod: PremiumPeriod?
	public let introductoryOffer: PremiumOffer?

	public init(
		id: String,
		localizedTitle: String,
		localizedPrice: String,
		price: Decimal,
		currencyCode: String?,
		subscriptionPeriod: PremiumPeriod?,
		introductoryOffer: PremiumOffer?
	) {
		self.id = id
		self.localizedTitle = localizedTitle
		self.localizedPrice = localizedPrice
		self.price = price
		self.currencyCode = currencyCode
		self.subscriptionPeriod = subscriptionPeriod
		self.introductoryOffer = introductoryOffer
	}
}
