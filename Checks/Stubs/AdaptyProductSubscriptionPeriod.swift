//
//  AdaptyProductSubscriptionPeriod.swift
//  IntegrationKit — Checks/Stubs
//
//  Stand-in for `AdaptyProductSubscriptionPeriod` (Adapty 2.10.x). `Unit` mirrors the five cases
//  of the real `AdaptyPeriodUnit` — `PremiumPeriod+Adapty.swift` switches over all five and has no
//  `default:`, so a missing or extra case would fail that file's build, not this one.
//

import Foundation

public struct AdaptyProductSubscriptionPeriod {
	public enum Unit {
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
