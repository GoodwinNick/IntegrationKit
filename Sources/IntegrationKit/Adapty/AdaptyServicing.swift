//
//  AdaptyServicing.swift
//  IntegrationKit
//

import AppTrackingTransparency
import Foundation

protocol AdaptyServicing: AnyObject {
	/// An empty `apiKey` is a legal configuration and leaves the layer inactive for the whole run —
	/// the same way an empty key silences Amplitude and an empty dev key silences AppsFlyer. Every
	/// operation below then becomes a no-op that records one line in `ConfigurationIssues`, and the
	/// SDK is never touched: `Adapty.activate` asserts on the key's shape and would take a DEBUG
	/// build down (AD-01 rows 1 and 7).
	///
	/// `attStatus` is the current tracking authorization, read by the composition root and handed
	/// over rather than read here: the status is state, not install data, so it is sent on every
	/// launch (AD-06 row 6), and a service that reached for `ATTrackingManager` itself would be
	/// reading a global the caller already owns — and one that blocks forever outside an app bundle.
	///
	/// `isTestsRunning` is the app's own answer to "is this a test run", and it leaves the layer
	/// inactive the same way an empty key does — with its own reason, because an app shipped
	/// without monetisation and a test run are different facts (AD-01 row 1). Without it a UI-test
	/// run of the app reaches the live Adapty project with the live key.
	func configure(
		apiKey: String,
		customerUserId: String,
		sessionsCounter: Int,
		placements: [String],
		analytics: AnalyticsTracking,
		attStatus: ATTrackingManager.AuthorizationStatus,
		isTestsRunning: Bool
	)

	/// Writes one custom attribute to the Adapty profile. A value Adapty would refuse (a key outside
	/// 1…30 characters of `A-Za-z0-9._-`, a value outside 1…50 characters) is not sent and lands in
	/// `ConfigurationIssues` instead of disappearing (AD-06 row 3).
	func setProfileValue(value: String, key: String)

	func hasPaywall(placement: String) -> Bool
	/// Why a placement has no paywall — `hasPaywall` alone cannot tell a screen whether to show a
	/// spinner or an empty state (AD-02 row 5).
	func paywallState(placement: String) -> PaywallState
	func hasProductsForPaywall(placement: String, id: String) -> Bool
	func hasProductsForPaywall(placement: String) -> Bool

	/// Re-attempts `getPaywall` for every configured placement that is missing or stale. Wired to
	/// `UIApplication.didBecomeActiveNotification` by the composition root (`IntegrationKit.swift`)
	/// — this protocol is the app-facing surface that trigger can reach.
	func refreshPaywalls()

	/// A remote-config value, with the reason when there is none: four different causes used to
	/// collapse into one `nil` (AD-07 row 1).
	func getRemoteValue<Type>(placement: String, key: String) -> RemoteValue<Type>

	func logPaywallOpen(placement: String)
	func buyProduct(placement: String, id: String, completion: ((AdaptyPurchaseResult) -> Void)?)

	/// Pushes the ATT answer to the Adapty profile. Sent by `configure` on every launch as well —
	/// the status is state, not install data, and a user who changes it in Settings would otherwise
	/// stay on the old value forever (AD-06 row 6).
	func updateAppTrackingTransparencyStatus(_ status: ATTrackingManager.AuthorizationStatus)

	/// Links AppsFlyer's conversion data to the Adapty profile so both describe the same
	/// attribution. A write that arrives before activation is queued and repeated afterwards
	/// instead of being lost — install data arrives once per install (AD-06 row 1).
	func updateAppsFlyerAttribution(_ data: [AnyHashable: Any], networkUserId: String?)
}
