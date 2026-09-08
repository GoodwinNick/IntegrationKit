//
//  AdaptyPremiumProviding.swift
//  IntegrationKit
//

import Adapty
import Foundation

/// The bit of Adapty the premium state actually needs. The profile arrives raw — turning it
/// into a premium answer is `PremiumService`'s job, because only it knows the level names.
public protocol AdaptyPremiumProviding: AnyObject {
	/// Fires whenever Adapty pushes a fresh profile.
	var premiumObserver: ((AdaptyProfile) -> Void)? { get set }
	/// Asks Adapty for the current profile. Stays silent when Adapty is unreachable.
	func refreshPremium()
}
