//
//  PremiumOffer.swift
//  IntegrationKit
//

import Foundation

/// An introductory offer on a product — free trial, pay-up-front, or pay-as-you-go discount.
/// Shaped after `AdaptyProductDiscount`, trimmed to what a paywall actually shows.
public struct PremiumOffer: Equatable, Sendable {
	public enum PaymentMode: String, Equatable, Sendable {
		case payAsYouGo
		case payUpFront
		case freeTrial
		case unknown
	}

	public let price: Decimal
	public let localizedPrice: String?
	public let period: PremiumPeriod
	public let numberOfPeriods: Int
	public let paymentMode: PaymentMode

	public init(price: Decimal, localizedPrice: String?, period: PremiumPeriod, numberOfPeriods: Int, paymentMode: PaymentMode) {
		self.price = price
		self.localizedPrice = localizedPrice
		self.period = period
		self.numberOfPeriods = numberOfPeriods
		self.paymentMode = paymentMode
	}
}
