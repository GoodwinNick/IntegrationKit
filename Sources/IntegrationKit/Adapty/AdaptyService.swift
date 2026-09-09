//
//  AdaptyService.swift
//  IntegrationKit
//
//  Implements the approved AD-01…AD-07 schemas. The single idea running through all of them:
//  Adapty answers through completions that are allowed never to arrive, and an answer that never
//  arrives is not the same as "no". Every call here therefore has a deadline, every silent branch
//  leaves a trace, and every cause that a retry cannot fix lands in `ConfigurationIssues`.
//
//  Written against Adapty 4.1.3. What the migration off 2.10.x moved, and where it is handled:
//  `getPaywall` → `getFlow`; one `remoteConfig` → an array of them, one per locale (AD-07 row 6);
//  `makePurchase` answering `Result<Void, _>` → `AdaptyPurchaseResult`, so a cancel and an
//  Ask-to-Buy are outcomes rather than error codes (AD-04); `updateAttribution` → the pair
//  `updateExternalAttribution` + `setIntegrationIdentifier`, which can fail apart (AD-06 row 10);
//  and an activation that hangs instead of failing, which took the retry queue's feeder with it
//  (AD-06 row 9).
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

	/// The test-run half of the same state, kept as its own sentence (AD-01 row 1). An app shipped
	/// without monetisation and a UI-test run both leave the layer inactive, but one is fixed by
	/// shipping a key and the other by nothing at all — one shared line would send whoever reads
	/// `configurationIssues` looking for a key that is perfectly fine.
	private static let testRunIssue = "The Adapty layer is inactive (the app reported a test run) — every Adapty call is a no-op for this run"

	private static let initialBackoff: TimeInterval = 0.5
	private static let maxBackoff: TimeInterval = 30

	/// How long this layer waits for the SDK before deciding without it — see `AdaptyDeadlines`.
	private let deadlines: AdaptyDeadlines

	private var flows: [String: AdaptyFlow] = [:] {
		didSet {
			self.observer?()
		}
	}
	private var flowLoadedAt: [String: Date] = [:]

	private var cachedProducts: [String: [AdaptyPaywallProduct]] = [:]
	/// The flow's remote configs, parsed once per loaded flow and keyed by locale.
	/// `AdaptyRemoteConfig.dictionary` is a computed property that re-runs `JSONSerialization` on
	/// every single access, and a paywall screen reads a handful of keys while it lays itself out
	/// (AD-07 row 5).
	private var remoteConfigs: [String: [String: [String: Any]]] = [:]
	/// The locales of `remoteConfigs[placement]`, in the order the dashboard listed them. Only the
	/// fallback needs the order — see `remoteConfig(placement:locale:)`.
	private var remoteConfigLocales: [String: [String]] = [:]

	/// What `configure` was called with — `refreshPaywalls()` needs the list again later.
	private var configuredPlacements: [String] = []

	/// Per-placement delay before the next self-retry of `loadFlow`. Doubles on every failure up
	/// to `maxBackoff`; a foreground trigger resets it.
	private var flowBackoff: [String: TimeInterval] = [:]
	/// Placements with a self-retry already scheduled — one pending retry per placement, ever.
	private var pendingFlowRetry: Set<String> = []
	/// Placements with a `getFlow` call in flight right now. Without it the foreground trigger
	/// fires a second request straight through the first: the SDK does not de-duplicate concurrent
	/// requests either, it opens a new task per call (AD-01 row 4, AD-02 row 3).
	private var loadingFlows: Set<String> = []
	/// Placements Adapty answered `badRequest` about — a placement that does not exist in the
	/// dashboard. Retrying those forever is what a typo used to buy (AD-02 row 1).
	private var unavailableFlows: Set<String> = []
	/// Placements whose product list failed to load. Kept apart from "no paywall": a purchase of an
	/// id nobody could list is a fallback case, a purchase of an id the paywall does not sell is a
	/// configuration mistake (AD-04 row 4).
	private var failedProductPlacements: Set<String> = []
	/// The same pair as `flowBackoff`/`pendingFlowRetry`, for the product listing. New in 0.3.0:
	/// 2.10.x's `ProductsManager` spent three attempts of its own before answering, which is why the
	/// old schema said there was nothing left to retry. 4.1.3's fetcher makes ONE pass, so the retry
	/// is ours or there is none (AD-03).
	private var productBackoff: [String: TimeInterval] = [:]
	private var pendingProductRetry: Set<String> = []

	/// `configure` ran with a non-empty key. Everything that talks to the SDK checks this first: an
	/// empty key (a test run, an app shipped without Adapty) must not reach the SDK at all —
	/// `AdaptyConfiguration.Builder` asserts on the key's shape and takes a DEBUG build down with it
	/// (AD-01 rows 1 and 7, AD-06 row 5).
	private(set) var isActive = false
	/// `Adapty.activate` came back. Distinct from `isActive`, and the distinction is AD-06 row 9: on
	/// 2.10.x a call made in the window between the two failed immediately with `.notActivated`, and
	/// that error is what put the write on the retry queue. On 4.1.3 `Adapty.activatedSDK` AWAITS an
	/// activation that is in flight, so the same call does not fail — it hangs, with no error and no
	/// queue entry. Everything sent inside this window therefore gets a deadline of its own.
	private var didActivate = false
	/// A profile has arrived in this process after activation. Until then a delegate push carries
	/// what the SDK had on disk from the last launch, and a stale "no premium" from disk must not
	/// close access for a user whose subscription is alive (AD-05 row 2).
	private var didLoadNetworkProfile = false
	/// Attribution payloads that have not landed yet, and the AppsFlyer ids that go with them —
	/// two queues, because on 4.1.3 they are two SDK calls that fail apart (AD-06 row 10). Install
	/// data arrives once per install: a write that happens before activation is lost forever, and a
	/// half-written one leaves the dashboard with campaign data it cannot attach to a user.
	///
	/// The repeat is safe by construction — the provider is always `.appsflyer` and the id is always
	/// the same one — so a second write can only confirm what is already there (AD-06 row 1).
	private var pendingAttributionPayloads: [[AnyHashable: Any]] = []
	private var pendingAppsFlyerIds: [String] = []
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
		attStatus: ATTrackingManager.AuthorizationStatus,
		// Defaults only so the checks' own call sites stay short: the composition root always
		// passes the app's answer, and the app always computes it.
		isTestsRunning: Bool = false,
		// AD-01, new on 4.x: Adapty's own attribution service. Off unless asked for — an app that
		// already runs AppsFlyer would otherwise send a second, independent install signal nobody
		// asked for, and the SDK's own default is off too.
		adaptyAttributionEnabled: Bool = false
	) {
		// AD-01 row 1: the app decides what a test run is and says so; the package never guesses.
		// First of all the guards, because everything below it talks to a live SDK with a live key
		// — which is what a UI-test run used to do, into the real Adapty project.
		guard !isTestsRunning else {
			recordInactive(operation: "configure", reason: Self.testRunIssue)
			return
		}
		configuredPlacements = placements
		guard !apiKey.isEmpty else {
			// An empty key is a legal configuration, not an error to swallow: the layer stays inactive
			// for the whole run and every operation becomes a safe no-op. It is also the only way to
			// keep Adapty quiet under test, the same way an empty key silences Amplitude and an empty
			// dev key silences AppsFlyer — and it is what keeps the builder's own
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
		debugLog(tag: Self.tag, "configure: customerUserId \(customerUserId), placements \(placements)")
		// Set before activate so the very first profile push is not missed. 4.1.3 holds the delegate
		// STRONGLY (`AdaptyDelegate.swift:39`), which is why the service no longer keeps a static
		// reference to itself the way it did on 2.10.x — the SDK is the owner now.
		Adapty.delegate = self
		let configuration = AdaptyConfiguration
			.builder(withAPIKey: apiKey)
			.with(customerUserId: customerUserId)
			// Observer mode off is what keeps the SDK watching the transaction queue. It is the
			// default too, and it is spelled out because turning it on silently would stop every
			// purchase this package makes from ever reaching the Adapty dashboard.
			.with(observerMode: false)
			.with(adaptyAttributionEnabled: adaptyAttributionEnabled)
			// Everything in this file assumes callbacks land on main — the caches, the flags and the
			// watchdogs are all touched from one queue and from no other.
			.with(callbackDispatchQueue: .main)
			.build()
		Adapty.activate(with: configuration) { [weak self] error in
			guard let self else { return }
			self.didActivate = true
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
				self.loadFlow(placement: placement)
			}
			self.flushPendingAttribution()
			self.watchForFirstProfile()
		}
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
	///
	/// On 4.1.3 these ids no longer travel on the profile builder — `with(amplitudeUserId:)` and
	/// `with(amplitudeDeviceId:)` are gone and the ids go through `setIntegrationIdentifier`, which
	/// is a different call with a failure of its own.
	private func linkAmplitudeUserId(deviceId: String, analytics: AnalyticsTracking) {
		guard let amplitudeDeviceId = analytics.deviceId, !amplitudeDeviceId.isEmpty else {
			// An empty string is not "no id" — it is an id that looks real and joins this profile to
			// nothing, forever, with no repeat. Leave the field unset and say why (AD-01 row 2).
			ConfigurationIssues.shared.record(
				"Analytics had no device id when the Adapty profile was linked — amplitudeDeviceId was left unset",
				tag: Self.tag
			)
			send("amplitude link") { completion in
				Adapty.setIntegrationIdentifier(.amplitudeUserId(deviceId), completion: completion)
			}
			return
		}
		debugLog(tag: Self.tag, "linking Adapty profile: amplitudeUserId \(deviceId), amplitudeDeviceId \(amplitudeDeviceId)")
		send("amplitude link") { completion in
			Adapty.setIntegrationIdentifier(.amplitudeUserId(deviceId), .amplitudeDeviceId(amplitudeDeviceId), completion: completion)
		}
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
	/// `Adapty.updateProfile` waits for a profile to exist, and when the profile cannot be created
	/// the SDK wakes only its *other* bucket of handlers — ours is never called, not even to report
	/// failure. On a cold offline first launch that means the write silently does not happen and
	/// nothing anywhere says so (AD-06 row 2).
	private func updateProfile(_ params: AdaptyProfileParameters, operation: String) {
		send(
			operation,
			timeoutIssue: "Adapty never answered a profile write (\(operation)) within \(Int(deadlines.write))s — the profile could not be created"
		) { completion in
			Adapty.updateProfile(params: params, completion)
		}
	}

	func updateAppsFlyerAttribution(_ data: [AnyHashable: Any], networkUserId: String?) {
		guard isActive else {
			// Queued rather than dropped: install data arrives once per install, and conversion data
			// racing ahead of activation is the normal order of events, not an edge case. With an
			// empty key activation never happens, so the queue is never flushed and the SDK is never
			// touched — which is what AD-06 row 5 requires.
			recordInactive(operation: "updateAppsFlyerAttribution")
			pendingAttributionPayloads.append(data)
			if let id = Self.usableNetworkUserId(networkUserId) {
				pendingAppsFlyerIds.append(id)
			}
			return
		}
		sendAttributionPayload(data)
		sendAppsFlyerId(networkUserId)
	}

	/// The campaign data itself. AD-06 row 11: `updateExternalAttribution` serialises the payload
	/// BEFORE it does anything asynchronous and answers `.wrongParam` on the caller's own stack when
	/// it will not serialise (`Adapty+Completion.swift:137-144`). A queue that re-queues on any
	/// failure therefore re-queues from inside its own drain, and does it again on every foreground
	/// pass, forever — the payload will never serialise, because it is the payload that is wrong.
	/// The check is made here instead, once, and the answer is a line nobody has to retry.
	private func sendAttributionPayload(_ data: [AnyHashable: Any]) {
		guard JSONSerialization.isValidJSONObject(data) else {
			ConfigurationIssues.shared.record(
				"AppsFlyer conversion data could not be encoded as JSON — Adapty refuses it and no retry can change that; check the values of \(data.keys.map { "\($0)" }.sorted())",
				tag: Self.tag
			)
			return
		}
		send("attribution payload") { completion in
			Adapty.updateExternalAttribution(data, provider: .appsflyer, completion)
		} onError: { [weak self] error in
			guard error.adaptyErrorCode != .wrongParam else {
				// Belt and braces for the guard above: the SDK's rules for what serialises are the
				// SDK's, and a payload that passes ours and fails theirs must still not come back.
				ConfigurationIssues.shared.record(
					"Adapty could not encode the AppsFlyer conversion data (wrongParam) — it is not retried, because the payload will not change",
					tag: Self.tag
				)
				return
			}
			// Losing this write means this user's campaign never pays back on any dashboard, and
			// nothing anywhere says so.
			debugLog(tag: Self.tag, level: .error, "retrying attribution payload at the next foreground pass")
			self?.pendingAttributionPayloads.append(data)
		}
	}

	/// The join key. Without it the dashboard has campaign data it cannot attach to a user, which is
	/// the half of AD-06 row 10 that is easiest to lose: it is a second call now, and it fails on its
	/// own.
	private func sendAppsFlyerId(_ networkUserId: String?) {
		guard let id = Self.usableNetworkUserId(networkUserId) else {
			// `AdaptyIntegrationIdentifier` trims its value and does not check for empty, so an empty
			// id is stored and matches nothing on the dashboard, permanently. The old
			// `updateAttribution` took the id as part of one call and this could not happen.
			ConfigurationIssues.shared.record(
				"The AppsFlyer id was empty — an empty join key matches nothing on the Adapty dashboard, so it was not written",
				tag: Self.tag
			)
			return
		}
		send("attribution id") { completion in
			Adapty.setIntegrationIdentifier(.appsflyerId(id), completion: completion)
		} onError: { [weak self] error in
			ConfigurationIssues.shared.record(
				"Adapty refused the AppsFlyer attribution id (\(error.adaptyErrorCode)) — the campaign data has no user to attach to until the write is repeated",
				tag: Self.tag
			)
			self?.pendingAppsFlyerIds.append(id)
		}
	}

	/// `nil` for an id that would be worse than none. Adapty trims the value itself, so whitespace is
	/// an empty id by the time it lands.
	private static func usableNetworkUserId(_ networkUserId: String?) -> String? {
		guard let trimmed = networkUserId?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
			return nil
		}
		return trimmed
	}

	/// AD-06 row 9, in one place. Every SDK call that answers with an optional error goes through
	/// here, so each of them leaves a trace whether it succeeds, fails, or never comes back at all:
	/// if nothing answered inside `deadlines.write`, that is recorded. The call itself may still be
	/// legitimately outstanding — what must not happen is that nobody is told.
	///
	/// This is the row's whole point. On 2.10.x a write made before activation finished failed
	/// immediately with `.notActivated`, and the failure is what put it on the retry queue. 4.1.3
	/// AWAITS an activation in flight instead, so the same call does not fail — it hangs, silently,
	/// with no error and no queue entry. An activation that never finishes therefore swallows every
	/// write made in that window, and this deadline is the only thing that notices.
	/// `timeoutIssue` is the line recorded when nothing answers at all. It has a default because most
	/// callers are row 9's case — a write parked behind an activation still in flight — but a profile
	/// write has a cause of its own (row 2), and naming the wrong one sends whoever reads
	/// `configurationIssues` looking in the wrong place.
	private func send(
		_ operation: String,
		timeoutIssue: String? = nil,
		call: (@escaping (AdaptyError?) -> Void) -> Void,
		onError: ((AdaptyError) -> Void)? = nil
	) {
		// An escaping completion cannot capture an `inout` flag, and the watchdog has to read what
		// the completion wrote — one box the two share. Adapty is activated with
		// `callbackDispatchQueue: .main` and the watchdog is scheduled on main, so it is only ever
		// touched from one queue.
		let answer = AnswerBox()
		call { error in
			answer.answered = true
			guard let error else {
				debugLog(tag: Self.tag, "\(operation) ok")
				return
			}
			debugLog(tag: Self.tag, level: .error, "\(operation) failed: \(error)")
			onError?(error)
		}
		DispatchQueue.main.asyncAfter(deadline: .now() + deadlines.write) { [weak self] in
			guard let self, !answer.answered else { return }
			ConfigurationIssues.shared.record(
				timeoutIssue ?? "Adapty never answered the \(operation) write within \(Int(self.deadlines.write))s — activation may still be in flight",
				tag: Self.tag
			)
		}
	}

	private final class AnswerBox {
		var answered = false
	}

	/// Both halves drain independently: one that failed does not hold the other back, and one that
	/// succeeded is not sent twice (AD-06 row 10).
	private func flushPendingAttribution() {
		let payloads = pendingAttributionPayloads
		let ids = pendingAppsFlyerIds
		guard !payloads.isEmpty || !ids.isEmpty else { return }
		pendingAttributionPayloads = []
		pendingAppsFlyerIds = []
		debugLog(tag: Self.tag, "flushing \(payloads.count) attribution payload(s) and \(ids.count) id(s)")
		for payload in payloads {
			sendAttributionPayload(payload)
		}
		for id in ids {
			sendAppsFlyerId(id)
		}
	}

	// MARK: - AD-02: placements and products.

	/// The one flow-loading path — `configure` and `refreshPaywalls()` both funnel through here.
	/// On a retryable failure it keeps re-attempting itself, spaced out with per-placement
	/// exponential backoff, until it succeeds: the approved schema says loading continues until it
	/// does.
	private func loadFlow(placement: String) {
		guard isActive else {
			recordInactive(operation: "loadFlow")
			return
		}
		// A placement Adapty rejected as unknown is not coming back — see the `badRequest` branch.
		guard !unavailableFlows.contains(placement) else { return }
		// One request per placement at a time. The SDK opens a new task per call and de-duplicates
		// nothing, so without this the foreground trigger fires straight through a request already
		// in flight.
		guard loadingFlows.insert(placement).inserted else { return }
		Adapty.getFlow(placementId: placement) { [weak self] result in
			guard let self else { return }
			self.loadingFlows.remove(placement)
			switch result {
				case .success(let flow):
					self.flowBackoff[placement] = nil
					self.flowLoadedAt[placement] = Date()
					// Parsed once, here — see `remoteConfigs`.
					self.storeRemoteConfigs(flow.remoteConfigs, placement: placement)
					self.flows[placement] = flow
					debugLog(tag: Self.tag, "flow loaded for '\(placement)'")
					self.fetchProductsForFlow(placement: placement)
				case .failure(let error):
					// A placement that does not exist in the dashboard answers `badRequest` (2003) and
					// will answer it forever: retrying is a typo burning battery for the life of the
					// process. A network failure is the opposite — that is what the backoff is for
					// (AD-02 row 1).
					if error.adaptyErrorCode == .badRequest {
						self.unavailableFlows.insert(placement)
						ConfigurationIssues.shared.record(
							"Adapty has no placement '\(placement)' (badRequest) — check the placement id against the dashboard",
							tag: Self.tag
						)
						self.observer?()
						return
					}
					let delay = self.flowBackoff[placement] ?? Self.initialBackoff
					self.flowBackoff[placement] = min(delay * 2, Self.maxBackoff)
					debugLog(tag: Self.tag, level: .error, "flow load failed for '\(placement)': \(error.adaptyErrorCode); next attempt in \(delay)s")
					// At most one retry in flight per placement. Without this, every foreground
					// trigger on a still-broken placement starts its own independent chain: a session
					// that foregrounds twenty times ends up with twenty of them hammering the SDK in
					// parallel, which is the spin the backoff exists to prevent.
					guard self.pendingFlowRetry.insert(placement).inserted else { return }
					DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
						guard let self else { return }
						self.pendingFlowRetry.remove(placement)
						guard self.flows[placement] == nil else { return }
						self.loadFlow(placement: placement)
					}
			}
		}
	}

	/// One dictionary per locale, parsed once. AD-07 rows 5 and 6.
	private func storeRemoteConfigs(_ configs: [AdaptyRemoteConfig], placement: String) {
		var byLocale: [String: [String: Any]] = [:]
		var order: [String] = []
		for config in configs {
			let locale = Self.normalised(config.locale)
			guard let dictionary = config.dictionary else {
				ConfigurationIssues.shared.record(
					"The remote config of '\(placement)' for locale '\(config.locale)' is not a JSON object — it is ignored",
					tag: Self.tag
				)
				continue
			}
			// A dashboard with the same locale twice is a dashboard mistake; the first row wins, and
			// the order below keeps the fallback deterministic either way.
			if byLocale[locale] == nil {
				order.append(locale)
			}
			byLocale[locale] = dictionary
		}
		remoteConfigs[placement] = byLocale
		remoteConfigLocales[placement] = order
		if byLocale.isEmpty {
			debugLog(tag: Self.tag, "flow '\(placement)' carries no remote config")
		}
	}

	private func fetchProductsForFlow(placement: String) {
		guard let flow = flows[placement] else { return }
		Adapty.getPaywallProducts(flow: flow) { [weak self] result in
			guard let self else { return }
			switch result {
				case .success(let products):
					self.productBackoff[placement] = nil
					self.failedProductPlacements.remove(placement)
					self.cachedProducts[placement] = products
				case .failure(let error):
					// Silence here is what left a purchase screen empty with no reason anywhere
					// (AD-02 row 2, AD-03 row 2). Code 1000 covers two causes the SDK itself cannot
					// separate — a paywall with no products, and products the store does not know — so
					// it goes into the line verbatim: one of them is fixed in the dashboard, the other
					// in App Store Connect (AD-02 row 6).
					self.failedProductPlacements.insert(placement)
					self.failedProductLoads += 1
					debugLog(tag: Self.tag, level: .error, "getPaywallProducts failed for '\(placement)': \(error.adaptyErrorCode)")
					self.scheduleProductRetry(placement: placement, after: error.adaptyErrorCode)
			}
		}
	}

	/// AD-03: 4.1.3's product fetcher makes one pass and stops, so a listing lost to a flaky network
	/// stays lost unless we ask again. `noProductIDsFound` is not asked again — it is the dashboard
	/// or App Store Connect answering, and both answer the same way every time.
	private func scheduleProductRetry(placement: String, after code: AdaptyError.ErrorCode) {
		guard code != .noProductIDsFound, code != .badRequest else { return }
		let delay = productBackoff[placement] ?? Self.initialBackoff
		productBackoff[placement] = min(delay * 2, Self.maxBackoff)
		guard pendingProductRetry.insert(placement).inserted else { return }
		DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
			guard let self else { return }
			self.pendingProductRetry.remove(placement)
			guard self.cachedProducts[placement] == nil else { return }
			self.fetchProductsForFlow(placement: placement)
		}
	}

	func hasPaywall(placement: String) -> Bool {
		return flows[placement] != nil
	}

	/// AD-02 row 5: `hasPaywall` cannot tell a screen whether to show a spinner or an empty state.
	/// This can.
	func paywallState(placement: String) -> PaywallState {
		if flows[placement] != nil { return .ready }
		if unavailableFlows.contains(placement) { return .unavailable }
		guard isActive, configuredPlacements.contains(placement) else { return .unavailable }
		return .loading
	}

	/// Re-attempts `getFlow` for every configured placement that is missing or stale. Fired by the
	/// composition root on `UIApplication.didBecomeActiveNotification` — this file stays UIKit-free,
	/// so the trigger itself lives in `IntegrationKit.swift`.
	///
	/// Returning to the foreground is a fresh signal, so a placement's pending backoff is not waited
	/// out: its delay is reset and the attempt is made immediately. It does not stack a second retry
	/// chain on the pending one, and it cannot start a second request for a placement already in
	/// flight — `loadFlow` holds both guards.
	///
	/// AD-02 row 4: a flow older than `deadlines.paywallTTL` is reloaded too. A price edited in the
	/// dashboard mid-session used to survive until the process died. This refreshes the flow and its
	/// remote configuration; the store product behind a price is pinned inside the SDK for the life
	/// of the process and no lever here reaches it — see AD-03 row 4 for that boundary.
	///
	/// AD-06 rows 7 and 10: the attribution queues drain here too. They need a second exit — the
	/// first one is the `activate` completion, which runs once per process, so a write the *already
	/// active* SDK refused had nobody left to retry it and sat in the queue until the process died.
	/// This is the cheaper of the two exits the schema allows: returning to the foreground is
	/// already wired, it is the moment a dropped network is most likely to be back, and it costs one
	/// line instead of a second observer.
	func refreshPaywalls() {
		flushPendingAttribution()
		for placement in configuredPlacements {
			if let loadedAt = flowLoadedAt[placement], Date().timeIntervalSince(loadedAt) < deadlines.paywallTTL {
				continue
			}
			flowBackoff[placement] = Self.initialBackoff
			loadFlow(placement: placement)
		}
	}

	func hasProductsForPaywall(placement: String, id: String) -> Bool {
		return cachedProducts[placement]?.contains(where: { $0.vendorProductId == id }) ?? false
	}

	func hasProductsForPaywall(placement: String) -> Bool {
		return cachedProducts[placement]?.first != nil
	}

	// MARK: - AD-07: remote values and impressions.

	func getRemoteValue<Type>(placement: String, key: String, locale: String) -> RemoteValue<Type> {
		guard flows[placement] != nil else { return .notReady }
		guard let config = remoteConfig(placement: placement, locale: locale) else { return .noConfig }
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

	/// AD-07 row 6. 4.1.3 hands over one remote config PER LOCALE and `getFlow` takes no locale to
	/// narrow them with — `getOnboarding` does, `getFlow` does not — so the choice is this layer's.
	/// Taking the first entry would put the dashboard's row order in charge of which language a
	/// paywall speaks, and reordering two rows in a web UI would silently reconfigure the app.
	///
	/// Exact locale first, then the language alone (`en-GB` is served by an `en` config), then the
	/// dashboard's first row — and that last one says so, because a paywall quietly rendering in the
	/// wrong language is a bug nobody reports and everybody sees.
	private func remoteConfig(placement: String, locale: String) -> [String: Any]? {
		guard let byLocale = remoteConfigs[placement], !byLocale.isEmpty else { return nil }
		let wanted = Self.normalised(locale)
		if let exact = byLocale[wanted] { return exact }
		let language = Self.language(of: wanted)
		if let order = remoteConfigLocales[placement],
		   let match = order.first(where: { Self.language(of: $0) == language }) {
			return byLocale[match]
		}
		let fallback = remoteConfigLocales[placement]?.first
		ConfigurationIssues.shared.record(
			"Adapty has no remote config for locale '\(locale)' on '\(placement)' — falling back to '\(fallback ?? "?")', so the paywall speaks the wrong language",
			tag: Self.tag
		)
		return fallback.flatMap { byLocale[$0] }
	}

	/// Adapty stores locales as the dashboard spells them (`en`, `en-US`, sometimes `en_US`), and the
	/// device spells them its own way. Comparing raw strings makes `en_US` and `en-US` two languages.
	private static func normalised(_ locale: String) -> String {
		locale.replacingOccurrences(of: "_", with: "-").lowercased()
	}

	private static func language(of normalisedLocale: String) -> String {
		String(normalisedLocale.prefix(while: { $0 != "-" }))
	}

	func logPaywallOpen(placement: String) {
		guard let flow = flows[placement] else {
			// No flow means no `variationId`, so there is nothing to send — but a purchase can
			// still happen through the StoreKit fallback, and an impression that never fires makes
			// that paywall's conversion look better than it is (AD-07 row 2).
			debugLog(tag: Self.tag, level: .error, "paywall shown for '\(placement)' with no Adapty flow loaded — impression not counted")
			return
		}
		Adapty.logShowFlow(flow) { error in
			if let error {
				// AD-07 row 4: a dropped impression must not look exactly like a sent one.
				debugLog(tag: Self.tag, level: .error, "logShowFlow failed for '\(placement)': \(error)")
			} else {
				debugLog(tag: Self.tag, "logShowFlow ok for '\(placement)'")
			}
		}
	}

	// MARK: - AD-04: purchase.

	func buyProduct(placement: String, id: String, completion: ((PurchaseVerdict) -> Void)?) {
		// Three causes used to share one `retryWithStoreKit`, and one of them was "the layer is off",
		// where a silent fallback means taking money through a side door the app never asked for
		// (AD-04 row 4).
		guard isActive else {
			recordInactive(operation: "buyProduct")
			completion?(.failed)
			return
		}
		guard flows[placement] != nil else {
			// Adapty never got the flow, so it cannot serve this purchase at all — exactly the
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
				case .success(let purchase):
					// The three outcomes of one completed call. Read through the accessors on purpose:
					// the success case carries a `VerificationResult<Transaction>` this package has no
					// use for, and destructuring it would tie us to a payload we never read.
					if purchase.isPurchaseCancelled {
						debugLog(tag: Self.tag, "purchase of \(id) was cancelled by the user")
						completion?(.cancelled)
					} else if purchase.isPurchasePending {
						// Ask to Buy waiting for a parent, or SCA. Neither bought nor refused: mapping
						// it to a failure invites a second attempt, mapping it to a success unlocks
						// premium for a purchase not yet made.
						debugLog(tag: Self.tag, "purchase of \(id) is pending approval")
						completion?(.pending)
					} else {
						debugLog(tag: Self.tag, "purchase of \(id) succeeded")
						completion?(.success)
					}
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

	/// The failure half of AD-04 in one place. Codes 0…14 are raw `SKError` values passed straight
	/// through, 1000+ are Adapty's own. The three outcomes that are NOT failures — bought, cancelled,
	/// pending — no longer come through here at all: 4.1.3 answers them inside a successful result.
	static func verdict(for code: AdaptyError.ErrorCode) -> PurchaseVerdict {
		switch code {
			case .paymentCancelled:
				// A cancel now arrives as `AdaptyPurchaseResult.userCancelled`, but the raw SKError can
				// still surface from the StoreKit layer, and answering `.failed` to it would offer a
				// retry for something the user just refused.
				return .cancelled
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
				//
				// `serverError` (2004) and `networkFailed` (2005) land here now, and that is AD-04
				// row 9. They used to answer `paidUnconfirmed`, which GRANTED premium on the theory
				// that Apple had charged and Adapty could not confirm it — but 2005 is equally what a
				// request that never left the device answers with, and nothing in the error tells the
				// two apart. A purchase that completed is `AdaptyPurchaseResult.success` now, and that
				// is the only thing this layer accepts as "paid". A real payer whose confirmation was
				// lost is picked up by the profile push and by `syncReceipt` — the paths that KNOW.
				return .failed
		}
	}

	/// AD-04, and the one method here that exists to do NOTHING.
	///
	/// `AdaptyDelegate` ships a default implementation of this that calls `Adapty.makePurchase`
	/// straight away (`AdaptyDelegate.swift:23-29`). Conforming to the protocol and staying silent is
	/// therefore not neutral — it signs the app up to buy whatever the App Store product page
	/// promoted: outside `PremiumService`'s single-purchase guard, with no paywall shown, no
	/// impression logged, and no `PurchaseOutcome` delivered to anybody.
	///
	/// The package has no way to ask the app whether it wants that, so it declines and says so. An
	/// app that wants promoted purchases can offer the product through its own paywall.
	func didReceivePromotedPurchase(_ product: AdaptyPromotedProduct) {
		debugLog(
			tag: Self.tag,
			"App Store promoted purchase of \(product.vendorProductId) was not started — the package never buys without a paywall"
		)
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
		guard let flow = flows[placement] else { return .notReady }
		let fetched: [AdaptyPaywallProduct]?? = await withTimeout(deadlines.call) {
			await withSingleResume { resume in
				Adapty.getPaywallProducts(flow: flow) { [weak self] result in
					switch result {
						case .success(let products):
							resume(products)
						case .failure(let error):
							// The same event as `fetchProductsForFlow`'s failure, on the other code
							// path, so it shares the counter (AD-02 row 2 / AD-03 row 2).
							self?.failedProductPlacements.insert(placement)
							self?.failedProductLoads += 1
							debugLog(tag: Self.tag, level: .error, "getPaywallProducts failed for '\(placement)': \(error.adaptyErrorCode)")
							resume(nil)
					}
				}
			}
		}
		guard let products = fetched.flatMap({ $0 }) else { return .failed }
		// The same cache `fetchProductsForFlow` writes; Adapty is activated with
		// `callbackDispatchQueue: .main`, so both writers land on the main queue.
		cachedProducts[placement] = products
		return .products(products.map(PremiumProduct.init(product:)))
	}

	func buy(productId: String, placement: String) async -> PurchaseVerdict {
		let answer: PurchaseVerdict? = await withTimeout(deadlines.purchase) {
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
	/// Not a receipt refresh despite the name: 4.1.3 is StoreKit 2 throughout, so this syncs
	/// transactions and never shows an App Store password prompt.
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

	private func recordInactive(operation: String, reason: String = AdaptyService.inactiveIssue) {
		debugLog(tag: Self.tag, level: .error, "inactive layer: \(operation) skipped")
		ConfigurationIssues.shared.record(reason, tag: Self.tag)
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

/// 4.1.3 requires `AdaptyDelegate` to be `Sendable`, and this service is not one: it is a class full
/// of mutable caches. It is safe all the same, and unchecked rather than proven because the reason
/// is a runtime fact the compiler cannot see — the SDK is activated with
/// `callbackDispatchQueue: .main`, every delegate call and every completion therefore arrives on the
/// main queue, and the only other entrances (`configure`, the app-facing forwards) are called from
/// the app's own main thread.
extension AdaptyService: @unchecked Sendable {}
