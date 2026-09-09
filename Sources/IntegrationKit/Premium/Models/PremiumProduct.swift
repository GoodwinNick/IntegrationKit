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
	/// The store's own formatted price. `nil` means the store gave none — a missing value, not an
	/// empty one: a button showing "" is indistinguishable from a button whose price failed to
	/// arrive, and the caller is the only one who can decide what to draw instead (AD-03 row 3).
	public let localizedPrice: String?
	public let price: Decimal
	public let currencyCode: String?
	public let subscriptionPeriod: PremiumPeriod?
	public let introductoryOffer: PremiumOffer?

	public init(
		id: String,
		localizedTitle: String,
		localizedPrice: String?,
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
