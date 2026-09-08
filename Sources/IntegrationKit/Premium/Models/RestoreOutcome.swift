//
//  RestoreOutcome.swift
//  IntegrationKit
//

import Foundation

/// The result of a restore attempt. `PremiumServicing.isPremium` already reflects `.restored`
/// by the time the completion fires — the caller never needs to poll for it.
public enum RestoreOutcome: Equatable {
	case restored
	case nothingToRestore
	case failed
	/// TEMPORARY: `PremiumService.restore` is a stub until step 5 implements it. This case is
	/// removed once real restore logic lands.
	case notImplemented
}
