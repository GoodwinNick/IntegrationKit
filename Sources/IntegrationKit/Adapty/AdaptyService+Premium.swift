//
//  AdaptyService+Premium.swift
//  IntegrationKit
//

import Foundation

/// `AdaptyService` already exposes `premiumObserver` and `refreshPremium()` — this is the
/// conformance, nothing more.
extension AdaptyService: AdaptyPremiumProviding {}
