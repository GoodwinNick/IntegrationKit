//
//  PremiumServicing.swift
//  IntegrationKit
//

import Foundation

/// The single public entry point into everything monetization-related. Adapty and the Apple
/// receipt are internal details behind this facade — nothing outside reaches them directly.
public protocol PremiumServicing: AnyObject {
	/// Current answer. Read synchronously, no network.
	var isPremium: Bool { get }

	/// Brings the layer up: seeds the cache from the legacy flag, subscribes to the Adapty push,
	/// first refresh.
	func start()

	/// Re-asks both sources. One verdict, one write, one notification.
	func refresh()

	/// Restores purchases. Internally: StoreKit → re-ask both sources → one verdict.
	/// The caller gets a ready answer, nothing more to fetch.
	func restore(completion: @escaping (RestoreOutcome) -> Void)

	/// Purchase. Updates state the same way `restore` does.
	func purchase(_ productId: String, placement: String, completion: @escaping (PurchaseOutcome) -> Void)

	/// Prices and product description — from here, not from Adapty or StoreKit directly.
	func product(_ productId: String, placement: String, completion: @escaping (PremiumProduct?) -> Void)
	func products(placement: String, completion: @escaping ([PremiumProduct]) -> Void)

	/// Paywalls and remote config — through the facade too, same subsystem.
	func hasPaywall(placement: String) -> Bool
	func remoteValue<T>(placement: String, key: String) -> T?
	func logPaywallOpen(placement: String)
}
