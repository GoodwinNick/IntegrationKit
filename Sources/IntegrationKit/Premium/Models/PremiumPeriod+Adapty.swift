//
//  PremiumPeriod+Adapty.swift
//  IntegrationKit
//

import Adapty
import Foundation

extension PremiumPeriod {
	/// One-to-one with `AdaptyProductSubscriptionPeriod` (Adapty 2.10.x) — the enum below has the
	/// same five cases as `AdaptyPeriodUnit`, so nothing can be lost in the mapping.
	init(period: AdaptyProductSubscriptionPeriod) {
		let unit: Unit
		switch period.unit {
			case .day:
				unit = .day
			case .week:
				unit = .week
			case .month:
				unit = .month
			case .year:
				unit = .year
			case .unknown:
				unit = .unknown
		}
		self.init(unit: unit, numberOfUnits: period.numberOfUnits)
	}
}
