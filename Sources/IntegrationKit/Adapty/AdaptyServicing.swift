//
//  AdaptyServicing.swift
//  IntegrationKit
//

import AppTrackingTransparency
import Foundation

protocol AdaptyServicing: AnyObject {
	func configure(apiKey: String, customerUserId: String, sessionsCounter: Int, placements: [String], analytics: AnalyticsTracking)
	func setProfileValue(value: String, key: String)
	func hasPaywall(placement: String) -> Bool
	func hasProductsForPaywall(placement: String, id: String) -> Bool
	func hasProductsForPaywall(placement: String) -> Bool
	/// Re-attempts `getPaywall` for every configured placement that is still missing. Wired to
	/// `UIApplication.didBecomeActiveNotification` by the composition root (`IntegrationKit.swift`)
	/// — this protocol is the app-facing surface that trigger can reach.
	func refreshPaywalls()
	func getRemoteValue<Type>(placement: String, key: String) -> Type?
	func logPaywallOpen(placement: String)
	func logOnboardingOpen(step: Int)
	func buyProduct(placement: String, id: String, completion: ((AdaptyPurchaseResult) -> Void)?)
	func integrateFirebase(appInstanceId: String)
	func integrateFacebook(id: String)
	/// Pushes the ATT answer to the Adapty profile right away instead of waiting for the next profile request.
	func updateAppTrackingTransparencyStatus(_ status: ATTrackingManager.AuthorizationStatus)
	/// Links AppsFlyer's conversion data to the Adapty profile so both describe the same attribution.
	func updateAppsFlyerAttribution(_ data: [AnyHashable: Any], networkUserId: String?)
}
