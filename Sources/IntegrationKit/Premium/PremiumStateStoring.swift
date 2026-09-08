//
//  PremiumStateStoring.swift
//  IntegrationKit
//

import Foundation

/// Where the resolved state lives between launches, plus the legacy flag screens observe.
public protocol PremiumStateStoring: AnyObject {
	var cached: PremiumState? { get set }
	var premium: Bool { get set }
}
