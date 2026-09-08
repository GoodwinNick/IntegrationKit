//
//  PremiumSource.swift
//  IntegrationKit
//

import Foundation

/// Who decided the current access state.
enum PremiumSource: String, Codable {
	case adapty
	case apple
	case legacy
	case none
}
