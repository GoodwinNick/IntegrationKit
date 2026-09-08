//
//  AdaptyServicing.swift
//  IntegrationKit
//

import AppTrackingTransparency
import Foundation

/// What Adapty answered about one purchase attempt. `retryWithStoreKit` is Adapty's own
/// signal that the request itself failed (offline, bad product, server error) — not a
/// premium decision, just "try the fallback purchase path instead".
public enum AdaptyPurchaseResult {
	case success
	case cancelled
	case retryWithStoreKit
	case failed
}

public protocol AdaptyServicing: AnyObject {
	func configure(apiKey: String, customerUserId: String, sessionsCounter: Int, placements: [String], analytics: AnalyticsTracking)
	func setProfileValue(value: String, key: String)
	func hasPaywall(placement: String) -> Bool
	func hasProductsForPaywall(placement: String, id: String) -> Bool
	func hasProductsForPaywall(placement: String) -> Bool
	func getRemoteValue<Type>(placement: String, key: String) -> Type?
	func getAbValue(placement: String) -> Int?
	func getBoolValue(placement: String, key: String) -> Bool
	func logPaywallOpen(placement: String)
	func logOnboardingOpen(step: Int)
	func updateAttribution(attribution: [AnyHashable: Any])
	func buyProduct(placement: String, id: String, completion: ((AdaptyPurchaseResult) -> Void)?)
	func integrateFirebase(appInstanceId: String)
	func integrateFacebook(id: String)
	/// Pushes the ATT answer to the Adapty profile right away instead of waiting for the next profile request.
	func updateAppTrackingTransparencyStatus(_ status: ATTrackingManager.AuthorizationStatus)
	/// Links AppsFlyer's conversion data to the Adapty profile so both describe the same attribution.
	func updateAppsFlyerAttribution(_ data: [AnyHashable: Any], networkUserId: String?)
}
