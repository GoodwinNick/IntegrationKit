//
//  AdaptySubscriptionOfferType.swift
//  IntegrationKit — Checks/Stubs
//
//  Stand-in for `AdaptySubscriptionOfferType` (Adapty 4.1.3,
//  `StoreKit/Entities/AdaptySubscriptionOfferType.swift:11-22`).
//
//  This type is the whole reason AD-03's "introductory offer" row is still open on 4.1.3. 2.10.x had
//  a dedicated `introductoryDiscount` field, so an offer read from it WAS introductory by
//  construction. 4.1.3 has one `subscriptionOffer` field that carries any of three kinds, and it is
//  a `RawRepresentable` STRUCT, not an enum — the compiler cannot force anyone to handle the other
//  two, and a backend that invents a fourth kind tomorrow produces a value none of the three
//  constants equal. Whoever reads `subscriptionOffer` has to test `offerType == .introductory`
//  themselves.
//

import Foundation

public struct AdaptySubscriptionOfferType: RawRepresentable, Equatable, Hashable {
	public let rawValue: String

	public init(rawValue: String) {
		self.rawValue = rawValue
	}

	public static let introductory = AdaptySubscriptionOfferType(rawValue: "introductory")
	public static let promotional = AdaptySubscriptionOfferType(rawValue: "promotional")
	public static let winBack = AdaptySubscriptionOfferType(rawValue: "win_back")
}
