//
//  AdaptySubscriptionPeriod.swift
//  IntegrationKit — Checks/Stubs
//
//  Stand-in for `AdaptySubscriptionPeriod` (Adapty 4.1.3,
//  `StoreKit/Entities/AdaptySubscriptionPeriod.swift`) — renamed from 2.10.x's
//  `AdaptyProductSubscriptionPeriod`. `Unit` mirrors the five cases of the real
//  `AdaptySubscriptionPeriod.Unit` (`AdaptySubscriptionPeriod.Unit.swift:11-17`) —
//  `PremiumPeriod+Adapty.swift` switches over all five and has no `default:`, so a missing or extra
//  case would fail that file's build, not this one.
//
//  Divergence, deliberate: the real initialiser NORMALISES (`:17-29`) — 7 days becomes 1 week, 12
//  months becomes 1 year. The stub keeps what it is given. Normalisation is the SDK's own arithmetic
//  on values it read from StoreKit; reproducing it here would only let a check assert that the STUB
//  divides correctly, and would hide a `PremiumPeriod` mapping that quietly relied on it.
//

import Foundation

public struct AdaptySubscriptionPeriod {
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
