//
//  PremiumPeriod+StoreKit.swift
//  IntegrationKit
//

import Foundation
import StoreKit

extension PremiumPeriod {
	/// A unit Apple adds later falls through `default` and is reported as `.unknown` rather than
	/// silently read as days.
	init(period: Product.SubscriptionPeriod) {
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
			default:
				unit = .unknown
		}
		self.init(unit: unit, numberOfUnits: period.value)
	}
}
