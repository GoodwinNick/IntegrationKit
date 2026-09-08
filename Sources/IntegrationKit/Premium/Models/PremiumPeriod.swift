//
//  PremiumPeriod.swift
//  IntegrationKit
//

import Foundation

/// A subscription period, shaped after `AdaptyProductSubscriptionPeriod` — the one field
/// `PremiumProduct` needs, without leaking the Adapty type through the facade.
public struct PremiumPeriod: Equatable {
	public enum Unit: String, Equatable {
		case day
		case week
		case month
		case year
		case unknown
	}

	public let unit: Unit
	public let numberOfUnits: Int

	public init(unit: Unit, numberOfUnits: Int) {
		self.unit = unit
		self.numberOfUnits = numberOfUnits
	}
}
