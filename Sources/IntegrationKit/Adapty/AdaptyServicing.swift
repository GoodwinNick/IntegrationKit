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
	/// SDK is never touched: `AdaptyConfiguration.Builder` asserts on the key's shape and would take
	/// a DEBUG build down (AD-01 rows 1 and 7).
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
	///
	/// `adaptyAttributionEnabled` switches on Adapty's own attribution service, new in 4.x. It is off
	/// unless asked for: an app that already runs AppsFlyer would otherwise start sending a second,
	/// independent install signal that nobody in the app asked for, and the SDK's own default is off
	/// too (`AdaptyConfiguration.swift:12-19`).
	func configure(
		apiKey: String,
		customerUserId: String,
		sessionsCounter: Int,
		placements: [String],
		analytics: AnalyticsTracking,
		attStatus: ATTrackingManager.AuthorizationStatus,
		isTestsRunning: Bool,
		adaptyAttributionEnabled: Bool
	)

	/// Writes one custom attribute to the Adapty profile. A value Adapty would refuse (a key outside
	/// 1…30 characters of `A-Za-z0-9._-`, a value outside 1…50 characters) is not sent and lands in
	/// `ConfigurationIssues` instead of disappearing (AD-06 row 3).
	func setProfileValue(value: String, key: String)

	/// The Adapty profile's own id, or `nil` when Adapty did not answer — never "there is no id".
	/// A projection of `profile()` onto a string, with the same deadline and the same meaning for
	/// `nil` (AD-05): this protocol carries it because `AdaptyProfile` is an SDK type and the app
	/// must not see one, and the app needs the id to match a user in Adapty with a user on its own
	/// backend.
	func profileId() async -> String?

	func hasPaywall(placement: String) -> Bool
	/// Why a placement has no paywall — `hasPaywall` alone cannot tell a screen whether to show a
	/// spinner or an empty state (AD-02 row 5).
	func paywallState(placement: String) -> PaywallState
	func hasProductsForPaywall(placement: String, id: String) -> Bool
	func hasProductsForPaywall(placement: String) -> Bool

	/// Re-attempts `getFlow` for every configured placement that is missing or stale. Wired to
	/// `UIApplication.didBecomeActiveNotification` by the composition root (`IntegrationKit.swift`)
	/// — this protocol is the app-facing surface that trigger can reach.
	func refreshPaywalls()

	/// A remote-config value, with the reason when there is none: four different causes used to
	/// collapse into one `nil` (AD-07 row 1).
	///
	/// `locale` is new in 0.3.0 and is the whole of AD-07 row 6. 4.1.3 hangs an ARRAY of remote
	/// configs off the flow, one per locale, and `getFlow` has no locale parameter to narrow it with
	/// — `getOnboarding` does, `getFlow` does not — so the choice is ours. Taking the first entry
	/// would let the dashboard's row order decide which language a paywall speaks, and reordering two
	/// rows in a web UI would silently reconfigure the app.
	func getRemoteValue<Type>(placement: String, key: String, locale: String) -> RemoteValue<Type>

	func logPaywallOpen(placement: String)
	func buyProduct(placement: String, id: String, completion: ((PurchaseVerdict) -> Void)?)

	/// Pushes the ATT answer to the Adapty profile. Sent by `configure` on every launch as well —
	/// the status is state, not install data, and a user who changes it in Settings would otherwise
	/// stay on the old value forever (AD-06 row 6).
	func updateAppTrackingTransparencyStatus(_ status: ATTrackingManager.AuthorizationStatus)

	/// Links AppsFlyer's conversion data to the Adapty profile so both describe the same
	/// attribution. A write that arrives before activation is queued and repeated afterwards
	/// instead of being lost — install data arrives once per install (AD-06 row 1).
	///
	/// On 4.1.3 this is a PAIR of SDK calls, not one: the payload goes to
	/// `updateExternalAttribution` and `networkUserId` — the id that joins the two systems — goes to
	/// `setIntegrationIdentifier`. They can fail apart, and each half is queued on its own
	/// (AD-06 row 10).
	func updateAppsFlyerAttribution(_ data: [AnyHashable: Any], networkUserId: String?)

	/// Links Firebase's own id for this install to the Adapty profile. The app reads it — Firebase
	/// hands `Analytics.appInstanceID()` to nobody else, and the package does not reach into another
	/// SDK for someone else's identifier — and the package owns what happens to it after that.
	///
	/// Queued until activation the way attribution is (AD-06): the id is available in the first
	/// frames of a launch, often before `Adapty.activate` has answered, and dropping it there would
	/// lose it on EVERY launch rather than on a failed one. It is not retried after a failed write,
	/// though — unlike install data, Firebase answers with the same id again next launch.
	///
	/// Not a profile attribute: 4.1.3 deleted `with(firebaseAppInstanceId:)` from the profile builder
	/// and this id now travels the integration-identifier channel, the same one `networkUserId` uses.
	/// So the 1…30/1…50 key and value limits do not apply to it, and it does not count against the
	/// 30-attribute ceiling.
	func setFirebaseAppInstanceId(_ id: String)
}

extension AdaptyServicing {
	/// The device's own locale, which is what a caller that does not care about locales means.
	func getRemoteValue<Type>(placement: String, key: String) -> RemoteValue<Type> {
		getRemoteValue(placement: placement, key: key, locale: Locale.current.identifier)
	}
}
