//
//  FakeAdaptySource.swift
//  IntegrationKit
//
//  TM-03 and the paywall half of TM-06: Adapty's seat in the graph during a test run. It implements
//  the same two internal protocols the real service does, so the arbiter above it is the production
//  one and PM-01…PM-08 apply without a single exception — a test that drives premium through here
//  is testing the real resolver, not a copy of it.
//
//  What it decides is only ever WHAT the source answers and WHEN. What that answer means is decided
//  by `PremiumResolver`, as always.
//

import Adapty
import AppTrackingTransparency
import Foundation

final class FakeAdaptySource: AdaptyPremiumProviding, AdaptyServicing {

	private static let tag = "TestMode"

	private let flags: TestModeFlags
	/// The access levels the app configured. A grant carries `-adaptyLevelId` when the test named one
	/// and this otherwise — "the package's default level" is the app's own first level, not a name
	/// the package invented (TM-03 row 5).
	private let defaultLevelId: String
	private let productIds: Set<String>
	private let sink: AnalyticsSink?

	/// TM-03 row 8: everything the layer holds dies with the source. Both deferred transitions are
	/// cancellable and nothing else outlives the process — no persistence, no repeating timer.
	private var scheduled: [DispatchWorkItem] = []

	init(flags: TestModeFlags, levels: Set<String>, productIds: Set<String>, sink: AnalyticsSink?) {
		self.flags = flags
		self.defaultLevelId = flags.adaptyLevelId ?? levels.sorted().first ?? "premium"
		self.productIds = productIds
		self.sink = sink
	}

	deinit {
		scheduled.forEach { $0.cancel() }
	}

	// MARK: - AdaptyPremiumProviding

	/// The layer is up. Silence is an answer this source did not give, not a layer that never came
	/// up: `isActive == false` would make `PremiumService.products` answer an empty list, and a test
	/// run must always have prices (TM-05 row 7).
	var isActive: Bool { true }

	/// Installed by `PremiumService.start()`, exactly as the real service's is. Scheduling the
	/// deferred transitions from here rather than from the composition root is what keeps them on the
	/// same channel as a real profile push (TM-03 row 2) — this source hands its answer to whoever
	/// was given the seat, and knows nothing about what happens next.
	var premiumObserver: ((AdaptyProfile, Bool) -> Void)? {
		didSet { scheduleTransitions() }
	}

	func profile() async -> AdaptyProfile? {
		switch flags.adapty {
			case .silent:
				debugLog(tag: Self.tag, "Adapty stays silent — the verdict is built from what is left")
				return nil
			case .grant:
				debugLog(tag: Self.tag, "Adapty grants level \(defaultLevelId)")
				return Self.grant(levelId: defaultLevelId)
			case .denial:
				debugLog(tag: Self.tag, "Adapty answers: no access level is active")
				return Self.denial()
		}
	}

	func products(placement: String) async -> AdaptyProductsAnswer {
		guard flags.adapty != .silent else { return .notReady }
		return .products(productIds.sorted().map { TestModeCatalog.product(id: $0, hasTrial: flags.hasTrial) })
	}

	func buy(productId: String, placement: String) async -> PurchaseVerdict {
		// TM-05 row 3: the store takes time. A purchase that answers instantly means "purchase in
		// flight" never exists, and the double tap, the endless spinner and the paywall reopened
		// mid-purchase are tested by nothing.
		await Self.wait(flags.purchaseDelay)
		switch flags.purchase {
			case .succeeds: return .success
			case .cancelled: return .cancelled
			case .pending: return .pending
			case .unavailable: return .unavailable
			case .fails: return .failed
		}
	}

	func remoteValue<T>(placement: String, key: String) -> RemoteValue<T> {
		// TM-06 row 2: a source that did not answer could not have brought values either — the whole
		// paywall space goes dark together, not key by key.
		guard flags.adapty != .silent else { return .notReady }
		guard let value = flags.paywallValues[key] else { return .notSet }
		guard let typed = value as? T else { return .wrongType }
		return .value(typed)
	}

	func logPaywallOpen(placement: String) {
		debugLog(tag: Self.tag, "paywall impression logged for '\(placement)'")
	}

	func hasPaywall(placement: String) -> Bool {
		flags.adapty != .silent
	}

	func paywallState(placement: String) -> PaywallState {
		// Silence is not "there is nothing there": the source has not answered, which is the state a
		// spinner is for.
		flags.adapty == .silent ? .loading : .ready
	}

	func syncReceipt() {
		debugLog(tag: Self.tag, "receipt sync asked for — nothing to upload in a test run")
	}

	func setProfileValue(value: String, key: String) {
		// TM-07 row 6: the only channel through which a UI test can see a profile attribute at all.
		sink?.record(profileValue: value, key: key)
		debugLog(tag: Self.tag, "profile value \(key)=\(value)")
	}

	// MARK: - AdaptyServicing
	// The app-facing half of the same seat. Nothing here reaches an SDK — the real service is not
	// built at all during a test run, so there is no live Adapty project to reach (invariant 5).

	func configure(
		apiKey: String,
		customerUserId: String,
		sessionsCounter: Int,
		placements: [String],
		analytics: AnalyticsTracking,
		attStatus: ATTrackingManager.AuthorizationStatus,
		isTestsRunning: Bool,
		adaptyAttributionEnabled: Bool
	) {
		debugLog(tag: Self.tag, "Adapty is faked for this run — the SDK is not activated")
	}

	func profileId() async -> String? {
		flags.adapty == .silent ? nil : "uitest-profile"
	}

	func hasProductsForPaywall(placement: String, id: String) -> Bool {
		flags.adapty != .silent && productIds.contains(id)
	}

	func hasProductsForPaywall(placement: String) -> Bool {
		flags.adapty != .silent && !productIds.isEmpty
	}

	func refreshPaywalls() {
		debugLog(tag: Self.tag, "paywall refresh asked for — the fake paywall is already there")
	}

	func getRemoteValue<Type>(placement: String, key: String, locale: String) -> RemoteValue<Type> {
		remoteValue(placement: placement, key: key)
	}

	func buyProduct(placement: String, id: String, completion: ((PurchaseVerdict) -> Void)?) {
		Task {
			let verdict = await buy(productId: id, placement: placement)
			DispatchQueue.main.async { completion?(verdict) }
		}
	}

	func updateAppTrackingTransparencyStatus(_ status: ATTrackingManager.AuthorizationStatus) {
		debugLog(tag: Self.tag, "ATT status \(status.rawValue) — nothing to send")
	}

	func updateAppsFlyerAttribution(_ data: [AnyHashable: Any], networkUserId: String?) {
		debugLog(tag: Self.tag, "attribution payload of \(data.count) keys — nothing to send")
	}

	func setFirebaseAppInstanceId(_ id: String) {
		debugLog(tag: Self.tag, "Firebase app instance id \(id) — nothing to send")
	}

	// MARK: - Deferred transitions

	/// `-premiumAfter` and `-noPremiumAfter`, delivered as profile pushes. The revoke is scheduled
	/// first so that two transitions asked for at the same second resolve the way TM-03 says they
	/// do — the removal lands, then the grant.
	private func scheduleTransitions() {
		guard premiumObserver != nil else { return }
		scheduled.forEach { $0.cancel() }
		scheduled = []
		if let after = flags.noPremiumAfter {
			push(isActive: false, after: after)
		}
		if let after = flags.premiumAfter {
			push(isActive: true, after: after)
		}
	}

	private func push(isActive: Bool, after delay: TimeInterval) {
		let levelId = defaultLevelId
		let item = DispatchWorkItem { [weak self] in
			guard let self, let observer = self.premiumObserver else { return }
			guard let profile = isActive ? Self.grant(levelId: levelId) : Self.denial() else { return }
			debugLog(tag: Self.tag, "deferred push after \(delay)s: access \(isActive ? "granted" : "revoked")")
			// Always verified: a fake source has no notion of an SDK's own disk copy, and TM-03
			// records that as an accepted limit rather than a gap to be filled.
			observer(profile, true)
		}
		scheduled.append(item)
		// The same queue every callback out of this layer uses (PM invariant 7).
		DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
	}

	// MARK: - Answers

	/// Thirty days out rather than lifetime: a dated grant is what a subscription really looks like,
	/// and it keeps `PremiumState.expiresAt` populated the way a real one does.
	private static func grant(levelId: String) -> AdaptyProfile? {
		TestModeProfile.make(levelId: levelId, isActive: true, expiresAt: Date().addingTimeInterval(30 * 24 * 3600))
	}

	private static func denial() -> AdaptyProfile? {
		TestModeProfile.make(levelId: "", isActive: false, expiresAt: nil)
	}

	private static func wait(_ seconds: TimeInterval) async {
		guard seconds > 0 else { return }
		try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
	}
}
