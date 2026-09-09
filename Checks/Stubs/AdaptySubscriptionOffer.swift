//
//  AdaptySubscriptionOffer.swift
//  IntegrationKit — Checks/Stubs
//
//  Stand-in for `AdaptySubscriptionOffer` (Adapty 4.1.3,
//  `StoreKit/Entities/AdaptySubscriptionOffer.swift`) — what 2.10.x's `AdaptyProductDiscount` turned
//  into. `PaymentMode` mirrors the real four cases
//  (`AdaptySubscriptionOffer.PaymentMode.swift:11-16`); `PremiumOffer+Adapty.swift` switches over all
//  four with no `default:`.
//
//  Two differences from the type it replaces, and both of them are why AD-03 stays open:
//
//  * `subscriptionPeriod` is NON-optional upstream (`:23`), same as the old discount — so a period
//    is still guaranteed once an offer exists.
//  * `offerType` (`:16-18`) is new, and it is the only thing that says whether this offer is the
//    introductory one. See `AdaptySubscriptionOfferType`.
//
//  Divergence, unavoidable: upstream `identifier` and `offerType` are computed from a `package`
//  `offerIdentifier` (`:12-20`) and the initialiser is internal. The stub stores both directly, so a
//  check can build a promotional offer and a win-back offer and watch what the mapping does with
//  them.
//

import Foundation

public struct AdaptySubscriptionOffer {
	public enum PaymentMode {
		case payAsYouGo
		case payUpFront
		case freeTrial
		case unknown
	}

	public let identifier: String?
	public let offerType: AdaptySubscriptionOfferType
	public let subscriptionPeriod: AdaptySubscriptionPeriod
	public let numberOfPeriods: Int
	public let paymentMode: PaymentMode
	public let localizedSubscriptionPeriod: String?
	public let localizedNumberOfPeriods: String?
	public let price: Decimal
	public let currencyCode: String?
	public let localizedPrice: String?

	public init(
		identifier: String? = nil,
		offerType: AdaptySubscriptionOfferType = .introductory,
		subscriptionPeriod: AdaptySubscriptionPeriod,
		numberOfPeriods: Int = 1,
		paymentMode: PaymentMode = .freeTrial,
		localizedSubscriptionPeriod: String? = nil,
		localizedNumberOfPeriods: String? = nil,
		price: Decimal = 0,
		currencyCode: String? = nil,
		localizedPrice: String? = nil
	) {
		self.identifier = identifier
		self.offerType = offerType
		self.subscriptionPeriod = subscriptionPeriod
		self.numberOfPeriods = numberOfPeriods
		self.paymentMode = paymentMode
		self.localizedSubscriptionPeriod = localizedSubscriptionPeriod
		self.localizedNumberOfPeriods = localizedNumberOfPeriods
		self.price = price
		self.currencyCode = currencyCode
		self.localizedPrice = localizedPrice
	}
}
