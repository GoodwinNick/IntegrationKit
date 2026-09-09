//
//  PremiumPeriod+Adapty.swift
//  IntegrationKit
//

import Adapty
import Foundation

extension PremiumPeriod {
	/// One-to-one with `AdaptySubscriptionPeriod` (Adapty 4.1.3, renamed from 2.10.x's
	/// `AdaptyProductSubscriptionPeriod`) — the enum below has the same five cases as its `Unit`, so
	/// nothing can be lost in the mapping.
	init(period: AdaptySubscriptionPeriod) {
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
