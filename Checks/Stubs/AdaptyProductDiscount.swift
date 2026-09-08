//
//  AdaptyProductDiscount.swift
//  IntegrationKit — Checks/Stubs
//
//  Stand-in for `AdaptyProductDiscount` (Adapty 2.10.x) — the fields `PremiumOffer+Adapty.swift`
//  reads. `subscriptionPeriod` is non-optional here, unlike `AdaptyPaywallProduct`'s own field of
//  the same type: the real SDK guarantees a discount always carries one.
//

import Foundation

public struct AdaptyProductDiscount {
	public enum PaymentMode {
		case payAsYouGo
		case payUpFront
		case freeTrial
		case unknown
	}

	public let price: Decimal
	public let localizedPrice: String?
	public let subscriptionPeriod: AdaptyProductSubscriptionPeriod
	public let numberOfPeriods: Int
	public let paymentMode: PaymentMode

	public init(
		price: Decimal,
		localizedPrice: String?,
		subscriptionPeriod: AdaptyProductSubscriptionPeriod,
		numberOfPeriods: Int,
		paymentMode: PaymentMode
	) {
		self.price = price
		self.localizedPrice = localizedPrice
		self.subscriptionPeriod = subscriptionPeriod
		self.numberOfPeriods = numberOfPeriods
		self.paymentMode = paymentMode
	}
}
