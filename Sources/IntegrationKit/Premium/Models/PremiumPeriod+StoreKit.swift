//
//  PremiumPeriod+StoreKit.swift
//  IntegrationKit
//

import Foundation
import StoreKit

extension PremiumPeriod {
	/// `SKProduct.PeriodUnit` has no `unknown` case of its own — a unit Apple adds later lands in
	/// `@unknown default` and is reported as `.unknown` rather than silently read as days.
	init(period: SKProductSubscriptionPeriod) {
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
			@unknown default:
				unit = .unknown
		}
		self.init(unit: unit, numberOfUnits: period.numberOfUnits)
	}
}
