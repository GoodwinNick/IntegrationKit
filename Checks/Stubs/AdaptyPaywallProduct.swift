//
//  AdaptyPaywallProduct.swift
//  IntegrationKit — Checks/Stubs
//
//  Stand-in for `AdaptyPaywallProduct` (Adapty 2.10.x) — the fields `PremiumProduct+Adapty.swift`
//  reads, plus `vendorProductId`, which `AdaptyService.buyProduct` matches its cache against.
//

import Foundation

public struct AdaptyPaywallProduct {
	public let vendorProductId: String
	public let localizedTitle: String
	public let localizedPrice: String?
	public let price: Decimal
	public let currencyCode: String?
	public let subscriptionPeriod: AdaptyProductSubscriptionPeriod?
	public let introductoryDiscount: AdaptyProductDiscount?

	public init(
		vendorProductId: String,
		localizedTitle: String = "",
		localizedPrice: String? = nil,
		price: Decimal = 0,
		currencyCode: String? = nil,
		subscriptionPeriod: AdaptyProductSubscriptionPeriod? = nil,
		introductoryDiscount: AdaptyProductDiscount? = nil
	) {
		self.vendorProductId = vendorProductId
		self.localizedTitle = localizedTitle
		self.localizedPrice = localizedPrice
		self.price = price
		self.currencyCode = currencyCode
		self.subscriptionPeriod = subscriptionPeriod
		self.introductoryDiscount = introductoryDiscount
	}
}
