//
//  RestoreOutcome.swift
//  IntegrationKit
//

import Foundation

/// The result of a restore attempt. `PremiumServicing.isPremium` already reflects `.restored`
/// by the time the completion fires — the caller never needs to poll for it.
public enum RestoreOutcome: Equatable, Sendable {
	case restored
	case nothingToRestore
	case failed
}
