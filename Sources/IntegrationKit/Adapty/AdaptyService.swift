//
//  AdaptyService.swift
//  IntegrationKit
//
//  Implements the approved AD-01…AD-07 schemas. The single idea running through all of them:
//  Adapty answers through completions that are allowed never to arrive, and an answer that never
//  arrives is not the same as "no". Every call here therefore has a deadline, every silent branch
//  leaves a trace, and every cause that a retry cannot fix lands in `ConfigurationIssues`.
//

import AppTrackingTransparency
import Foundation
import Adapty

final class AdaptyService: AdaptyServicing, AdaptyPremiumProviding {

	/// Log tag of every line this layer prints.
	private static let tag = "AdaptyService"

	/// The one sentence recorded when the layer is inactive. Fixed text on purpose: AD-06 row 5
	/// asks for exactly ONE line no matter how many operations are attempted, and
	/// `ConfigurationIssues` de-duplicates by text.
	private static let inactiveIssue = "The Adapty layer is inactive (empty API key) — every Adapty call is a no-op for this run"

	private static let initialPaywallBackoff: TimeInterval = 0.5
	private static let maxPaywallBackoff: TimeInterval = 30

	/// AD-05 row 3: `Adapty.delegate` is `weak`, and the only strong reference to this service is a
	/// field of the struct `IntegrationKit.configure` returns. An app that does not keep that struct
	/// alive loses every profile push for the rest of the process, silently — nothing logs it and
	/// nothing can. One retained service per process is the cheapest honest fix.
	private static var retained: AdaptyService?

	/// How long this layer waits for the SDK before deciding without it — see `AdaptyDeadlines`.
	private let deadlines: AdaptyDeadlines

	private var paywalls: [String: AdaptyPaywall] = [:] {
		didSet {
			self.observer?()
		}
	}
	private var paywallLoadedAt: [String: Date] = [:]

	private var cachedProducts: [String: [AdaptyPaywallProduct]] = [:]
	/// The paywall's remote config, parsed once per loaded paywall. `AdaptyPaywall.remoteConfig` is
	/// a computed property that re-runs `JSONSerialization` on every single access, and a paywall
	/// screen reads a handful of keys while it lays itself out (AD-07 row 5).
	private var remoteConfigs: [String: [String: Any]] = [:]

	/// What `configure` was called with — `refreshPaywalls()` needs the list again later.
	private var configuredPlacements: [String] = []

	/// Per-placement delay before the next self-retry of `loadPaywall`. Doubles on every failure up
	/// to `maxPaywallBackoff`; a foreground trigger resets it.
	private var paywallBackoff: [String: TimeInterval] = [:]
	/// Placements with a self-retry already scheduled — one pending retry per placement, ever.
	private var pendingPaywallRetry: Set<String> = []
	/// Placements with a `getPaywall` call in flight right now. Without it the foreground trigger
	/// fires a second request straight through the first: the SDK does not de-duplicate concurrent
	/// requests either, it opens a new task per call (AD-01 row 4, AD-02 row 3).
	private var loadingPaywalls: Set<String> = []
	/// Placements Adapty answered `badRequest` about — a placement that does not exist in the
	/// dashboard. Retrying those forever is what a typo used to buy (AD-02 row 1).
	private var unavailablePaywalls: Set<String> = []
	/// Placements whose product list failed to load. Kept apart from "no paywall": a purchase of an
	/// id nobody could list is a fallback case, a purchase of an id the paywall does not sell is a
	/// configuration mistake (AD-04 row 4).
	private var failedProductPlacements: Set<String> = []

	/// `configure` ran with a non-empty key. Everything that talks to the SDK checks this first: an
	/// empty key (a test run, an app shipped without Adapty) must not reach the SDK at all —
	/// `Adapty.activate` asserts on the key's shape and takes a DEBUG build down with it
	/// (AD-01 rows 1 and 7, AD-06 row 5).
	private(set) var isActive = false
	/// A profile has arrived in this process after activation. Until then a delegate push carries
	/// what the SDK had on disk from the last launch, and a stale "no premium" from disk must not
	/// close access for a user whose subscription is alive (AD-05 row 2).
	private var didLoadNetworkProfile = false
	/// Attribution writes that have not landed yet. Install data arrives once per install: a write
	/// that happens before activation is lost forever. The repeat is safe by construction — the
	/// source is always `.appsflyer`, and Adapty locks the attribution source on the first write
	/// that lands, so a second one can only confirm what is already there (AD-06 row 1).
	private var pendingAttribution: [(data: [AnyHashable: Any], networkUserId: String?)] = []
	/// How many product loads failed. A screen can say "try again later" instead of showing an
	/// empty list with no reason anywhere (AD-02 row 2, AD-03 row 2 — the same event, two paths).
	private(set) var failedProductLoads = 0
	/// How many `syncReceipt()` calls came back with an error (AD-05 row 4).
	private(set) var failedSyncs = 0

	var observer: (() -> Void)?
	/// Fires whenever Adapty pushes a fresh profile. `isVerified` is false while the profile can
	/// only have come from the SDK's own storage — see `didLoadNetworkProfile`.
	var premiumObserver: ((AdaptyProfile, Bool) -> Void)?

	/// Deadlines are injectable so a check can drive a three-minute wait in a third of a second.
	init(deadlines: AdaptyDeadlines = .default) {
		self.deadlines = deadlines
	}

	// MARK: - AD-01: configuration and activation.

	func configure(
		apiKey: String,
		customerUserId: String,
		sessionsCounter: Int,
		placements: [String],
		analytics: AnalyticsTracking,
		attStatus: ATTrackingManager.AuthorizationStatus
	) {
		configuredPlacements = placements
		guard !apiKey.isEmpty else {
			// An empty key is a legal configuration, not an error to swallow: the layer stays inactive
			// for the whole run and every operation becomes a safe no-op. It is also the only way to
			// keep Adapty quiet under test, the same way an empty key silences Amplitude and an empty
			// dev key silences AppsFlyer — and it is what keeps `Adapty.activate`'s own
			// `assert(apiKey.count >= 41 && apiKey.starts(with: "public_live"))` from taking a DEBUG
			// build down on the same stack frame.
			recordInactive(operation: "configure")
			return
		}
		// The same assert, one frame earlier. An empty key is not the only shape that trips it: an
		// obfuscated key decrypted wrong, or a key pasted from another service, is 41 characters of
		// something that is not ours — and it would take the DEBUG build down here, before any
		// network call. Invariant 2 of the schema is that nothing in this layer ever traps.
		guard apiKey.count >= 41, apiKey.hasPrefix("public_live") else {
			ConfigurationIssues.shared.record(
				"The Adapty API key is not shaped like one (\(apiKey.count) characters, expected 41+ beginning with 'public_live') — the layer stays inactive",
				tag: Self.tag
			)
			return
		}
		if placements.isEmpty {
			ConfigurationIssues.shared.record(
				"Adapty is configured with no placements — no paywall will be warmed up",
				tag: Self.tag
			)
		}
		isActive = true
		// See `retained`: without this the delegate dies with the app's last reference to the kit.
		Self.retained = self
		debugLog(tag: Self.tag, "configure: customerUserId \(customerUserId), placements \(placements)")
		// Set before activate so the very first profile push is not missed.
		Adapty.delegate = self
		Adapty.activate(apiKey, observerMode: false, customerUserId: customerUserId, dispatchQueue: .main, { [weak self] error in
			guard let self else { return }
			if let error {
				// The only failure `activate` reports is its own double-activation guard (3005):
				// network and key errors never reach this completion at all. Repeating the rest would
				// mean a second delegate, a second identity write and a second paywall warm-up in one
				// process (AD-01 row 3).
				ConfigurationIssues.shared.record(
					"Adapty activate was rejected (\(error)) — the rest of the configuration is skipped",
					tag: Self.tag
				)
				return
			}
			self.linkAmplitudeUserId(deviceId: customerUserId, analytics: analytics)
			let dateFormatter = DateFormatter()
			dateFormatter.dateFormat = "dd-MM-yyyy"
			self.setProfileValue(value: dateFormatter.string(from: .now), key: "lastUsedDay")
			self.setProfileValue(value: sessionsCounter.description, key: "launchSession")
			// AD-06 row 6: the ATT answer is state, not install data. The app pushes it once, right
			// after the system dialog; a user who changes it later in Settings would otherwise stay
			// on the old status forever. Sending the current value on every launch costs one write.
			self.updateAppTrackingTransparencyStatus(attStatus)
			for placement in placements {
				self.loadPaywall(placement: placement)
			}
			self.flushPendingAttribution()
			self.watchForFirstProfile()
		})
	}

	/// AD-01 row 5: an invalid key, or a network that never comes back, surfaces as an error
	/// nowhere — the SDK keeps re-creating the profile once a second until the process dies (its
	/// own source carries a `TODO: Dont repeat if wrong apiKey` at that spot). The only observable
	/// symptom is that no profile ever arrives, so that is what is watched.
	private func watchForFirstProfile() {
		DispatchQueue.main.asyncAfter(deadline: .now() + deadlines.firstProfile) { [weak self] in
			guard let self, !self.didLoadNetworkProfile else { return }
			ConfigurationIssues.shared.record(
				"Adapty delivered no profile within \(Int(self.deadlines.firstProfile))s of activation — check the API key and the network",
				tag: Self.tag
			)
		}
	}

	/// Puts our own device id on the Adapty side so an Adapty event and an analytics event describe
	/// the same user.
	private func linkAmplitudeUserId(deviceId: String, analytics: AnalyticsTracking) {
		let builder = AdaptyProfileParameters.Builder()
			.with(amplitudeUserId: deviceId)
		if let amplitudeDeviceId = analytics.deviceId {
			builder.with(amplitudeDeviceId: amplitudeDeviceId)
			debugLog(tag: Self.tag, "linking Adapty profile: amplitudeUserId \(deviceId), amplitudeDeviceId \(amplitudeDeviceId)")
		} else {
			// An empty string is not "no id" — it is an id that looks real and joins this profile to
			// nothing, forever, with no repeat. Leave the field unset and say why (AD-01 row 2).
			ConfigurationIssues.shared.record(
				"Analytics had no device id when the Adapty profile was linked — amplitudeDeviceId was left unset",
				tag: Self.tag
			)
		}
		updateProfile(builder.build(), operation: "amplitude link")
	}

	// MARK: - AD-06: identity and attribution.

	func setProfileValue(value: String, key: String) {
		guard isActive else {
			recordInactive(operation: "setProfileValue")
			return
		}
		// Adapty's own rules, read out of the SDK sources: a key is 1…30 characters of
		// `A-Za-z0-9._-`, a string value is 1…50 characters. Breaking either throws out of the
		// builder before any network call — and the value is often not ours to trust: the live input
		// here is a deep link value straight off the network, which disappears at character 51
		// (AD-06 row 3).
		if let problem = Self.customAttributeProblem(value: value, key: key) {
			ConfigurationIssues.shared.record(
				"Adapty profile attribute '\(key)' was not written: \(problem)",
				tag: Self.tag
			)
			return
		}
		do {
			let builder = try AdaptyProfileParameters.Builder()
				.with(customAttribute: value, forKey: key)
			updateProfile(builder.build(), operation: "profile attribute '\(key)'")
		} catch {
			// Unreachable while the check above mirrors the SDK's rules — kept because those rules
			// live in the SDK and can change under us, and a silent `catch` is exactly what this row
			// is about.
			ConfigurationIssues.shared.record(
				"Adapty refused profile attribute '\(key)': \(error)",
				tag: Self.tag
			)
		}
	}

	/// `nil` when Adapty will accept the pair, otherwise the reason, phrased for a log line.
	static func customAttributeProblem(value: String, key: String) -> String? {
		if key.isEmpty || key.count > 30 || key.range(of: "[^A-Za-z0-9._-]", options: .regularExpression) != nil {
			return "the key must be 1…30 characters of A-Za-z0-9._- (got \(key.count): '\(key)')"
		}
		if value.isEmpty || value.count > 50 {
			return "the value must be 1…50 characters (got \(value.count))"
		}
		return nil
	}

	func updateAppTrackingTransparencyStatus(_ status: ATTrackingManager.AuthorizationStatus) {
		guard isActive else {
			recordInactive(operation: "updateAppTrackingTransparencyStatus")
			return
		}
		let builder = AdaptyProfileParameters.Builder()
			.with(appTrackingTransparencyStatus: status)
		updateProfile(builder.build(), operation: "ATT status \(status.rawValue)")
	}

	/// Every profile write goes through here, so every one of them has a deadline and a trace.
	///
	/// `Adapty.updateProfile` waits for a profile to exist (`waitCreatingProfile: true`), and when
	/// the profile cannot be created the SDK wakes only its *other* bucket of handlers — ours is
	/// never called, not even to report failure. On a cold offline first launch that means the write
	/// silently does not happen and nothing anywhere says so (AD-06 row 2).
	private func updateProfile(_ params: AdaptyProfileParameters, operation: String) {
		// Adapty is activated with `dispatchQueue: .main` and the watchdog below is scheduled on
		// main, so this flag is only ever touched from one queue.
		var answered = false
		Adapty.updateProfile(params: params) { error in
			answered = true
			if let error {
				debugLog(tag: Self.tag, level: .error, "\(operation) failed: \(error)")
			} else {
				debugLog(tag: Self.tag, "\(operation) ok")
			}
		}
		DispatchQueue.main.asyncAfter(deadline: .now() + deadlines.write) { [weak self] in
			guard let self, !answered else { return }
			ConfigurationIssues.shared.record(
				"Adapty never answered a profile write (\(operation)) within \(Int(self.deadlines.write))s — the profile could not be created",
				tag: Self.tag
			)
		}
	}

	func updateAppsFlyerAttribution(_ data: [AnyHashable: Any], networkUserId: String?) {
		guard isActive else {
			// Queued rather than dropped: install data arrives once per install, and conversion data
			// racing ahead of activation is the normal order of events, not an edge case. With an
			// empty key activation never happens, so the queue is never flushed and the SDK is never
			// touched — which is what AD-06 row 5 requires.
			recordInactive(operation: "updateAppsFlyerAttribution")
			pendingAttribution.append((data: data, networkUserId: networkUserId))
			return
		}
		Adapty.updateAttribution(data, source: .appsflyer, networkUserId: networkUserId) { [weak self] error in
			if let error {
				// Losing this write means this user's campaign never pays back on any dashboard, and
				// nothing anywhere says so.
				debugLog(tag: Self.tag, level: .error, "updateAttribution failed: \(error) — queued for retry")
				self?.pendingAttribution.append((data: data, networkUserId: networkUserId))
			} else {
				debugLog(tag: Self.tag, "updateAttribution ok, networkUserId \(networkUserId ?? "nil")")
			}
		}
	}

	private func flushPendingAttribution() {
		guard !pendingAttribution.isEmpty else { return }
		let queued = pendingAttribution
		pendingAttribution = []
		debugLog(tag: Self.tag, "flushing \(queued.count) queued attribution write(s)")
		for item in queued {
			updateAppsFlyerAttribution(item.data, networkUserId: item.networkUserId)
		}
	}

	// MARK: - AD-02: paywalls and products.

	/// The one paywall-loading path — `configure` and `refreshPaywalls()` both funnel through here.
	/// On a retryable failure it keeps re-attempting itself, spaced out with per-placement
	/// exponential backoff, until it succeeds: the approved schema says loading continues until it
	/// does.
	private func loadPaywall(placement: String) {
		guard isActive else {
			recordInactive(operation: "loadPaywall")
			return
		}
		// A placement Adapty rejected as unknown is not coming back — see the `badRequest` branch.
		guard !unavailablePaywalls.contains(placement) else { return }
		// One request per placement at a time. The SDK opens a new task per call and de-duplicates
		// nothing, so without this the foreground trigger fires straight through a request already
		// in flight.
		guard loadingPaywalls.insert(placement).inserted else { return }
		Adapty.getPaywall(placementId: placement, { [weak self] result in
			guard let self else { return }
			self.loadingPaywalls.remove(placement)
			switch result {
				case .success(let paywall):
					self.paywallBackoff[placement] = nil
					self.paywallLoadedAt[placement] = Date()
					// Parsed once, here — see `remoteConfigs`.
					let config = paywall.remoteConfig
					self.remoteConfigs[placement] = config
					if config == nil {
						debugLog(tag: Self.tag, "paywall '\(placement)' carries no remote config")
					}
					self.paywalls[placement] = paywall
					debugLog(tag: Self.tag, "paywall loaded for '\(placement)'")
					self.fetchProductsForPaywall(placement: placement)
				case .failure(let error):
					// A placement that does not exist in the dashboard answers `badRequest` (2003) and
					// will answer it forever: retrying is a typo burning battery for the life of the
					// process. A network failure is the opposite — that is what the backoff is for
					// (AD-02 row 1).
					if error.adaptyErrorCode == .badRequest {
						self.unavailablePaywalls.insert(placement)
						ConfigurationIssues.shared.record(
							"Adapty has no placement '\(placement)' (badRequest) — check the placement id against the dashboard",
							tag: Self.tag
						)
						self.observer?()
						return
					}
					let delay = self.paywallBackoff[placement] ?? Self.initialPaywallBackoff
					self.paywallBackoff[placement] = min(delay * 2, Self.maxPaywallBackoff)
					debugLog(tag: Self.tag, level: .error, "paywall load failed for '\(placement)': \(error.adaptyErrorCode); next attempt in \(delay)s")
					// At most one retry in flight per placement. Without this, every foreground
					// trigger on a still-broken placement starts its own independent chain: a session
					// that foregrounds twenty times ends up with twenty of them hammering the SDK in
					// parallel, which is the spin the backoff exists to prevent.
					guard self.pendingPaywallRetry.insert(placement).inserted else { return }
					DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
						guard let self else { return }
						self.pendingPaywallRetry.remove(placement)
						guard self.paywalls[placement] == nil else { return }
						self.loadPaywall(placement: placement)
					}
			}
		})
	}

	private func fetchProductsForPaywall(placement: String) {
		guard let paywall = paywalls[placement] else { return }
		Adapty.getPaywallProducts(paywall: paywall, { [weak self] result in
			guard let self else { return }
			switch result {
				case .success(let products):
					self.failedProductPlacements.remove(placement)
					self.cachedProducts[placement] = products
				case .failure(let error):
					// The SDK has already spent its own three attempts and two seconds by now, so there
					// is nothing left to retry — but silence here is what left a purchase screen empty
					// with no reason anywhere (AD-02 row 2, AD-03 row 2). Code 1000 covers two causes
					// the SDK itself cannot separate — a paywall with no products, and products the
					// store does not know — so it goes into the line verbatim: one of them is fixed in
					// the dashboard, the other in App Store Connect (AD-02 row 6).
					self.failedProductPlacements.insert(placement)
					self.failedProductLoads += 1
					debugLog(tag: Self.tag, level: .error, "getPaywallProducts failed for '\(placement)': \(error.adaptyErrorCode)")
			}
		})
	}

	func hasPaywall(placement: String) -> Bool {
		return paywalls[placement] != nil
	}

	/// AD-02 row 5: `hasPaywall` cannot tell a screen whether to show a spinner or an empty state.
	/// This can.
	func paywallState(placement: String) -> PaywallState {
		if paywalls[placement] != nil { return .ready }
		if unavailablePaywalls.contains(placement) { return .unavailable }
		guard isActive, configuredPlacements.contains(placement) else { return .unavailable }
		return .loading
	}

	/// Re-attempts every configured placement that is missing or stale. Fired by the composition
	/// root on `UIApplication.didBecomeActiveNotification` — this file stays UIKit-free, so the
	/// trigger itself lives in `IntegrationKit.swift`.
	///
	/// Returning to the foreground is a fresh signal, so a placement's pending backoff is not waited
	/// out: its delay is reset and the attempt is made immediately. It does not stack a second retry
	/// chain on the pending one, and it cannot start a second request for a placement already in
	/// flight — `loadPaywall` holds both guards.
	///
	/// AD-02 row 4: a paywall older than `deadlines.paywallTTL` is reloaded too. A price edited in the
	/// dashboard mid-session used to survive until the process died. This refreshes the paywall and
	/// its remote configuration; the `SKProduct` behind a price is pinned inside the SDK for the
	/// life of the process and no lever here reaches it — see AD-03 row 4 for that boundary.
	func refreshPaywalls() {
		for placement in configuredPlacements {
			if let loadedAt = paywallLoadedAt[placement], Date().timeIntervalSince(loadedAt) < deadlines.paywallTTL {
				continue
			}
			paywallBackoff[placement] = Self.initialPaywallBackoff
			loadPaywall(placement: placement)
		}
	}

	func hasProductsForPaywall(placement: String, id: String) -> Bool {
		return cachedProducts[placement]?.contains(where: { $0.vendorProductId == id }) ?? false
	}

	func hasProductsForPaywall(placement: String) -> Bool {
		return cachedProducts[placement]?.first != nil
	}

	// MARK: - AD-07: remote values and impressions.

	func getRemoteValue<Type>(placement: String, key: String) -> RemoteValue<Type> {
		guard paywalls[placement] != nil else { return .notReady }
		guard let config = remoteConfigs[placement] else { return .noConfig }
		guard let raw = config[key] else { return .notSet }
		guard let value = raw as? Type else {
			// The value is there and is of another type — a dashboard mistake, not a missing key. It
			// is the one branch of the five nobody would ever find on their own (AD-07 row 1).
			ConfigurationIssues.shared.record(
				"Adapty remote config '\(key)' on '\(placement)' holds a \(type(of: raw)), not the \(Type.self) the app asked for",
				tag: Self.tag
			)
			return .wrongType
		}
		return .value(value)
	}

	func logPaywallOpen(placement: String) {
		guard let paywall = paywalls[placement] else {
			// No paywall means no `variationId`, so there is nothing to send — but a purchase can
			// still happen through the StoreKit fallback, and an impression that never fires makes
			// that paywall's conversion look better than it is (AD-07 row 2).
			debugLog(tag: Self.tag, level: .error, "paywall shown for '\(placement)' with no Adapty paywall loaded — impression not counted")
			return
		}
		Adapty.logShowPaywall(paywall) { error in
			if let error {
				// AD-07 row 4: a dropped impression must not look exactly like a sent one.
				debugLog(tag: Self.tag, level: .error, "logShowPaywall failed for '\(placement)': \(error)")
			} else {
				debugLog(tag: Self.tag, "logShowPaywall ok for '\(placement)'")
			}
		}
	}

	// MARK: - AD-04: purchase.

	func buyProduct(placement: String, id: String, completion: ((AdaptyPurchaseResult) -> Void)?) {
		// Three causes used to share one `retryWithStoreKit`, and one of them was "the layer is off",
		// where a silent fallback means taking money through a side door the app never asked for
		// (AD-04 row 4).
		guard isActive else {
			recordInactive(operation: "buyProduct")
			completion?(.failed)
			return
		}
		guard paywalls[placement] != nil else {
			// Adapty never got the paywall, so it cannot serve this purchase at all — exactly the
			// case the StoreKit fallback exists for.
			debugLog(tag: Self.tag, level: .error, "'\(placement)' has no paywall loaded → retryWithStoreKit for \(id)")
			completion?(.retryWithStoreKit)
			return
		}
		guard let products = cachedProducts[placement] else {
			debugLog(
				tag: Self.tag,
				level: .error,
				"'\(placement)' has no product list (load failed: \(failedProductPlacements.contains(placement))) → retryWithStoreKit for \(id)"
			)
			completion?(.retryWithStoreKit)
			return
		}
		guard let product = products.first(where: { $0.vendorProductId == id }) else {
			// The placement loaded, its products loaded, and this id is not among them. That is the
			// app asking for a product its own paywall does not sell — a configuration mistake, not a
			// reason to buy it behind the paywall's back.
			ConfigurationIssues.shared.record(
				"'\(id)' is not on Adapty placement '\(placement)' — the paywall lists \(products.map(\.vendorProductId))",
				tag: Self.tag
			)
			completion?(.unavailable)
			return
		}
		Adapty.makePurchase(product: product) { result in
			switch result {
				case .success:
					debugLog(tag: Self.tag, "purchase of \(id) succeeded")
					completion?(.success)
				case let .failure(error):
					let verdict = Self.verdict(for: error.adaptyErrorCode)
					// The one line an incident starts from: which product, what the SDK said in its own
					// words, and what this layer decided about it. `String(reflecting:)` picks up
					// `AdaptyError`'s debug description — its `localizedDescription` is the useless
					// Foundation default, because the type carries no localized description at all
					// (AD-04 row 6).
					debugLog(
						tag: Self.tag,
						level: .error,
						"purchase of \(id) failed: code \(error.adaptyErrorCode), \(String(reflecting: error)) → \(verdict)"
					)
					if verdict == .unavailable {
						ConfigurationIssues.shared.record(
							"'\(id)' cannot be purchased on this device (\(error.adaptyErrorCode)) — the paywall should stop offering it",
							tag: Self.tag
						)
					}
					completion?(verdict)
			}
		}
	}

	/// The whole of AD-04 in one place. Codes 0…14 are raw `SKError` values passed straight through,
	/// 1000+ are Adapty's own.
	static func verdict(for code: AdaptyError.ErrorCode) -> AdaptyPurchaseResult {
		switch code {
			case .paymentCancelled:
				// A user cancel arrives as the raw SKError (2), not wrapped in a purchase failure —
				// verified in the SDK's own error mapping, so this branch is right as it stands.
				return .cancelled
			case .serverError, .networkFailed:
				// Adapty only reaches its own validation after StoreKit reports the transaction as
				// purchased, so these two mean "Apple charged, we could not confirm". Sending them to
				// the StoreKit fallback is how a paid user used to be asked to pay twice
				// (AD-04 row 2).
				return .paidUnconfirmed
			case .invalidOfferIdentifier, .invalidSignature, .missingOfferParams, .invalidOfferPrice:
				// A promotional offer the store refuses to sign. This fails BEFORE any payment is
				// queued, and the fallback would buy the same product at full price, silently, right
				// after the user was shown a discount (AD-04 row 3).
				return .unavailable
			case .cantMakePayments, .paymentNotAllowed, .storeProductNotAvailable, .clientInvalid, .paymentInvalid:
				// Permanent for this device or this storefront: parental controls, a product missing
				// from the store. Offering a retry only fails the same way (AD-04 row 5).
				return .unavailable
			case .productRequestFailed, .noProductIDsFound, .productPurchaseFailed, .unknown:
				// Adapty could not get as far as a payment. Worth one attempt through StoreKit.
				return .retryWithStoreKit
			default:
				// Temporary, or ours to fix but not the user's to work around: a later retry is fine.
				return .failed
		}
	}

	// MARK: - AdaptyPremiumProviding: async over Adapty's own callbacks.
	// Every wrapper goes through `withSingleResume` — never `withCheckedContinuation` directly —
	// and every one of them has a deadline. `withSingleResume` protects against a second answer;
	// it does nothing about the first one never arriving, which is the failure mode that actually
	// happens here.

	/// `nil` means Adapty did not answer — never "no premium".
	///
	/// Being offline is not what breaks this: the SDK falls back to the stored profile when the
	/// network request fails. What breaks it is a first launch whose profile could not be created —
	/// the SDK retries that once a second forever and never wakes this call (AD-05 row 1).
	func profile() async -> AdaptyProfile? {
		guard isActive else {
			// AD-05 row 5: every failure answers `nil` to the caller, which is right — but exactly one
			// of them is a configuration mistake, and that one has to be visible.
			recordInactive(operation: "profile")
			return nil
		}
		let answer: AdaptyProfile?? = await withTimeout(deadlines.call) {
			await withSingleResume { resume in
				Adapty.getProfile { result in
					switch result {
						case .success(let profile):
							resume(profile)
						case .failure(let error):
							debugLog(tag: Self.tag, level: .error, "getProfile failed: \(error.adaptyErrorCode)")
							resume(nil)
					}
				}
			}
		}
		guard let answer else {
			debugLog(tag: Self.tag, level: .error, "getProfile did not answer within \(Int(deadlines.call))s — premium is decided without it")
			return nil
		}
		if answer != nil {
			didLoadNetworkProfile = true
		}
		return answer
	}

	/// Products of a placement, already wrapped so the caller never sees an Adapty type. Uses the
	/// cache `configure` filled and fetches only when it is still empty, which is the normal case
	/// for a paywall opened right after launch.
	func products(placement: String) async -> AdaptyProductsAnswer {
		if let cached = cachedProducts[placement], !cached.isEmpty {
			return .products(cached.map(PremiumProduct.init(product:)))
		}
		// AD-03 row 1: "the paywall has not arrived" and "listing its products failed" are different
		// answers, and the caller has to choose between a spinner and an error message.
		guard let paywall = paywalls[placement] else { return .notReady }
		let fetched: [AdaptyPaywallProduct]?? = await withTimeout(deadlines.call) {
			await withSingleResume { resume in
				Adapty.getPaywallProducts(paywall: paywall, { [weak self] result in
					switch result {
						case .success(let products):
							resume(products)
						case .failure(let error):
							// The same event as `fetchProductsForPaywall`'s failure, on the other code
							// path, so it shares the counter (AD-02 row 2 / AD-03 row 2).
							self?.failedProductPlacements.insert(placement)
							self?.failedProductLoads += 1
							debugLog(tag: Self.tag, level: .error, "getPaywallProducts failed for '\(placement)': \(error.adaptyErrorCode)")
							resume(nil)
					}
				})
			}
		}
		guard let products = fetched.flatMap({ $0 }) else { return .failed }
		// The same cache `fetchProductsForPaywall` writes; Adapty is activated with
		// `dispatchQueue: .main`, so both writers land on the main queue.
		cachedProducts[placement] = products
		return .products(products.map(PremiumProduct.init(product:)))
	}

	func buy(productId: String, placement: String) async -> AdaptyPurchaseResult {
		let answer: AdaptyPurchaseResult? = await withTimeout(deadlines.purchase) {
			await withSingleResume { resume in
				self.buyProduct(placement: placement, id: productId) { resume($0) }
			}
		}
		guard let answer else {
			// Ask to Buy waiting for a parent, or an SDK that simply never called back. Waiting is a
			// verdict: the caller shows "waiting for approval" and — the half that matters more — the
			// purchase machinery is free again instead of refusing every later purchase in this
			// process (AD-04 row 1).
			debugLog(tag: Self.tag, level: .error, "purchase of \(productId) got no answer in \(Int(deadlines.purchase))s → pending")
			return .pending
		}
		return answer
	}

	func remoteValue<T>(placement: String, key: String) -> RemoteValue<T> {
		getRemoteValue(placement: placement, key: key)
	}

	// MARK: - AD-05: profile and receipt.

	/// Asks Adapty to upload the local purchase to its backend and refresh the profile. Called by
	/// `PremiumService` right after a StoreKit fallback purchase succeeds, to close the window the
	/// local-purchase mark exists to cover.
	///
	/// Not a receipt refresh despite the name: on iOS 15+ this goes down the StoreKit 2 path and
	/// syncs transactions, so it never shows an App Store password prompt.
	func syncReceipt() {
		guard isActive else {
			recordInactive(operation: "syncReceipt")
			return
		}
		Adapty.restorePurchases { [weak self] result in
			switch result {
				case .success:
					debugLog(tag: Self.tag, "syncReceipt ok")
				case .failure(let error):
					// The moment Adapty is guaranteed not to know about the purchase is exactly the
					// moment this failure matters, so it does not get to be silent (AD-05 row 4).
					self?.failedSyncs += 1
					ConfigurationIssues.shared.record(
						"Adapty did not pick up a local purchase (\(error.adaptyErrorCode)) — premium rests on the local mark until it does",
						tag: Self.tag
					)
			}
		}
	}

	// MARK: - Shared.

	private func recordInactive(operation: String) {
		debugLog(tag: Self.tag, level: .error, "inactive layer: \(operation) skipped")
		ConfigurationIssues.shared.record(Self.inactiveIssue, tag: Self.tag)
	}
}

extension AdaptyService: AdaptyDelegate {
	/// Adapty pushes this on activation, on any profile change, and after a dashboard grant.
	///
	/// The first push of a process carries what the SDK had on disk from the last launch, not an
	/// answer from the network — the profile manager hands the stored profile to the delegate the
	/// moment it is built, before any request is made. A stale "no premium" from disk must not read
	/// as a checked denial, so provenance travels with the profile (AD-05 row 2).
	func didLoadLatestProfile(_ profile: AdaptyProfile) {
		let isVerified = didLoadNetworkProfile
		didLoadNetworkProfile = true
		premiumObserver?(profile, isVerified)
	}
}
