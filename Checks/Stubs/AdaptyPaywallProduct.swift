//
//  AdaptyPaywallProduct.swift
//  IntegrationKit — Checks/Stubs
//
//  Stand-in for `AdaptyPaywallProduct` (Adapty 4.1.3,
//  `Placements/Entities/AdaptyPaywallProduct.swift`) — the fields `PremiumProduct+Adapty.swift`
//  reads, plus `vendorProductId`, which `AdaptyService.buyProduct` matches its cache against.
//
//  Divergence, unavoidable and the reason this file cannot shrink: upstream every one of these
//  fields except `subscriptionOffer` is a computed property of the `AdaptyProduct` protocol reading
//  `skProduct: StoreKit.Product` (`StoreKit/Entities/AdaptyProduct.swift:10-87`), and
//  `StoreKit.Product` has no initialiser at all — it only ever comes back from the App Store. A
//  harness therefore cannot build a real product, and the stub stores what upstream computes.
//
//  The names are the contract: as long as `vendorProductId`, `localizedTitle`, `localizedPrice`,
//  `price`, `currencyCode` and `subscriptionPeriod` are spelled the same here as upstream,
//  `PremiumProduct+Adapty.swift` compiles unchanged against both. A field that upstream computes and
//  the stub forgot would fail the real build, not this one — which is the right way round.
//
//  `introductoryDiscount` is gone: 4.1.3 has one `subscriptionOffer: AdaptySubscriptionOffer?`
//  (`:29`) that may be introductory, promotional or win-back. AD-03.
//

import Foundation

public struct AdaptyPaywallProduct {
	public let vendorProductId: String
	public let localizedTitle: String
	public let localizedPrice: String?
	public let price: Decimal
	public let currencyCode: String?
	public let subscriptionPeriod: AdaptySubscriptionPeriod?
	public let subscriptionOffer: AdaptySubscriptionOffer?

	public init(
		vendorProductId: String,
		localizedTitle: String = "",
		localizedPrice: String? = nil,
		price: Decimal = 0,
		currencyCode: String? = nil,
		subscriptionPeriod: AdaptySubscriptionPeriod? = nil,
		subscriptionOffer: AdaptySubscriptionOffer? = nil
	) {
		self.vendorProductId = vendorProductId
		self.localizedTitle = localizedTitle
		self.localizedPrice = localizedPrice
		self.price = price
		self.currencyCode = currencyCode
		self.subscriptionPeriod = subscriptionPeriod
		self.subscriptionOffer = subscriptionOffer
	}
}
