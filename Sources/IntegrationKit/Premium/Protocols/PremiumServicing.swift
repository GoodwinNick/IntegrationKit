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

	/// PM-10: whether one access level is open right now — `"lifetime"`, `"remote_play"`, as named in
	/// the Adapty dashboard and passed in `levels`. Synchronous, no network, like `isPremium`.
	///
	/// - With a `productLevels` map: the level's own verdict. Buying a product opens only the level
	///   the map ties it to; a change to any level posts `.premiumDidChange`.
	/// - Without one: `isPremium`, because the kit cannot tell which purchase opened which level.
	/// - A level not in `levels`: `false`, and one line in `configurationIssues`.
	func hasAccess(level: String) -> Bool

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

	/// PM-09: which subscriptions Adapty reports as active right now — the store product ids, as in
	/// `productIds` and on the paywall. `isPremium` says "there is access"; this says "through which
	/// subscription", for the screen that has to pick a cohort (a weekly user and a yearly one are not
	/// offered the same upsell).
	///
	/// Asks Adapty and nobody else, with the same short deadline a purchase or a restore gets — a
	/// person is looking at the screen that calls this. Read-only: the verdict, the cache and the
	/// legacy flag stay exactly as they were, and `.premiumDidChange` is never posted by it.
	///
	/// - A set: Adapty answered. `[]` means "answered, nothing active" — not the same as `nil`.
	///   Exactly what Adapty marks active, a grace period included, a refunded or expired one not.
	///   Not filtered by `productIds`: a subscription the app no longer sells comes back too. Offline,
	///   the profile the SDK saved last answers, as it is.
	/// - `nil`: Adapty did not answer — the layer is off, or no profile came before the deadline.
	///   Treat it as "unknown", never as "none". Asking again is allowed; nothing is cached.
	///
	/// `completion` runs exactly once, on the main queue, and never inside this call. Two calls at once
	/// are two requests.
	func activeSubscriptionIds(completion: @escaping (Set<String>?) -> Void)

	/// Prices and product description — from here, not from Adapty or StoreKit directly.
	func product(_ productId: String, placement: String, completion: @escaping (PremiumProduct?) -> Void)
	/// Everything the placement sells, priced. Two sources, one list: Adapty owns the paywall and
	/// says which products are on it, the store owns the storefront and says what they cost. The
	/// store's price wins wherever it answers; a product the store stayed silent about keeps
	/// Adapty's copy rather than dropping out of the list.
	///
	/// A placement that has not loaded yet, or one Adapty could not list, does not give an empty
	/// paywall: the `productIds` handed to `IntegrationKit.configure(...)` are priced straight from
	/// the store instead. Empty means neither source knew anything.
	func products(placement: String, completion: @escaping ([PremiumProduct]) -> Void)

	/// Paywalls and remote config — through the facade too, same subsystem.
	func hasPaywall(placement: String) -> Bool

	/// Why a placement has no paywall: `hasPaywall` answers `false` both while an attempt is still
	/// in flight and when the placement does not exist, and a screen cannot choose between a
	/// spinner and an empty state from one boolean.
	func paywallState(placement: String) -> PaywallState

	/// A remote-config value together with the reason when there is none. Call `.value` on the
	/// result for the plain optional; match the case to tell "ask again in a second" from "the
	/// dashboard never set this" from "the dashboard set it to the wrong type".
	func remoteValue<T>(placement: String, key: String) -> RemoteValue<T>

	/// Reports that this placement's paywall was shown, so Adapty counts the impression against the
	/// variation it served. Call it once, as the screen appears.
	///
	/// A placement whose paywall has not loaded carries no variation to attribute the impression to,
	/// so nothing is sent — a purchase can still go through the fallback, and the skipped impression
	/// leaves a trace rather than disappearing.
	func logPaywallOpen(placement: String)

	/// Everything the package could not make work and no retry will fix — an empty key, a device id
	/// that arrived too late, a placement that does not exist in the dashboard, a product the
	/// paywall does not sell. One line per cause, in the order they were first seen. Empty is the
	/// healthy state; anything here is an integration mistake worth an assert in a test or a
	/// non-fatal in Crashlytics.
	var configurationIssues: [String] { get }
}

public extension PremiumServicing {
	/// PM-10 row 27: an app's own fake written before 0.11.0 keeps compiling, and answers `isPremium`.
	func hasAccess(level: String) -> Bool {
		isPremium
	}
}
