//
//  AdaptyPromotedProduct.swift
//  IntegrationKit — Checks/Stubs
//
//  Stand-in for `AdaptyPromotedProduct` (Adapty 4.1.3,
//  `StoreKit/Entities/AdaptyPromotedProduct.swift:10-18`) — what the delegate is handed when the
//  user taps a promoted in-app purchase on the App Store page.
//
//  It exists in this harness for one reason: `AdaptyDelegate` ships a DEFAULT implementation of
//  `didReceivePromotedPurchase` that immediately calls `Adapty.makePurchase(product:)`
//  (`AdaptyDelegate.swift:24-29`). Conforming and staying silent is not neutral — it opts the app
//  into a purchase nobody in the app asked for, outside `PremiumService`'s single-purchase guard.
//
//  Divergence, unavoidable: upstream this conforms to `AdaptyProduct` and every field but
//  `subscriptionOffer` is computed from `skProduct: StoreKit.Product`, which cannot be constructed.
//  The stub stores `vendorProductId` directly.
//

import Foundation

public struct AdaptyPromotedProduct {
	public let vendorProductId: String
	public let subscriptionOffer: AdaptySubscriptionOffer?

	public init(vendorProductId: String, subscriptionOffer: AdaptySubscriptionOffer? = nil) {
		self.vendorProductId = vendorProductId
		self.subscriptionOffer = subscriptionOffer
	}
}
