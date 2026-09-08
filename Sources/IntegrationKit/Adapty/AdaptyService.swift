//
//  AdaptyService.swift
//  IntegrationKit
//

import AppTrackingTransparency
import Foundation
import Adapty

final class AdaptyService: AdaptyServicing, AdaptyPremiumProviding {

	private var paywalls: [String: AdaptyPaywall] = [:] {
		didSet {
			self.observer?()
		}
	}

	private var cachedProducts: [String: [AdaptyPaywallProduct]] = [:]

	/// What `configure` was called with — `refreshPaywalls()` needs the list again later, and
	/// `configure` only ever had it as a local parameter.
	private var configuredPlacements: [String] = []

	/// Per-placement delay before `loadPaywall`'s next self-retry. Absent means the starting
	/// delay. Doubles on every failure up to `maxPaywallBackoff`; `refreshPaywalls()` resets a
	/// placement's entry back to `initialPaywallBackoff` before retrying it immediately.
	private var paywallBackoff: [String: TimeInterval] = [:]
	/// Placements with a self-retry already scheduled. One pending retry per placement, ever —
	/// see `loadPaywall`.
	private var pendingPaywallRetry: Set<String> = []
	private static let initialPaywallBackoff: TimeInterval = 0.5
	private static let maxPaywallBackoff: TimeInterval = 30

	var observer: (() -> Void)?
	/// Fires whenever Adapty pushes a fresh profile (activation, any profile change). Callers
	/// derive their own premium decision from `AdaptyProfile.accessLevels`.
	var premiumObserver: ((AdaptyProfile) -> Void)?
	/// Fires right after a purchase succeeds, before Adapty's own profile push round-trips back
	/// through `premiumObserver` — lets a caller apply an optimistic premium state immediately.
	var onPurchaseSucceeded: (() -> Void)?

	init() {}

	func configure(apiKey: String, customerUserId: String, sessionsCounter: Int, placements: [String], analytics: AnalyticsTracking) {
		configuredPlacements = placements
		// Set before activate so the very first profile push is not missed.
		Adapty.delegate = self
		Adapty.activate(apiKey, observerMode: false, customerUserId: customerUserId, dispatchQueue: .main, { _ in
			self.linkAmplitudeUserId(deviceId: customerUserId, analytics: analytics)
			let dateFormatter = DateFormatter()
			dateFormatter.dateFormat = "dd-MM-yyyy"
			self.setProfileValue(value: dateFormatter.string(from: .now), key: "lastUsedDay")
			self.setProfileValue(value: sessionsCounter.description, key: "launchSession")
			for placement in placements {
				self.loadPaywall(placement: placement)
			}
		})
	}

	func setProfileValue(value: String, key: String) {
		do {
			var builder = try AdaptyProfileParameters.Builder()
				.with(customAttribute: value, forKey: key)
			Adapty.updateProfile(params: builder.build()) { [weak self] error in
				if error != nil {
					debugLog("Error ADAPTYCLIENT.updateProfile \(key) \(value)")
				} else {
					debugLog("OK ADAPTYCLIENT.updateProfile \(key) \(value)")
				}
			}
		} catch {
			debugLog("Error ADAPTYCLIENT.setProfileValue \(key) \(value)")

		}

	}
	private func fetchProductsForPaywall(placement: String) {
		if let paywall = paywalls[placement] {
			Adapty.getPaywallProducts(paywall: paywall, { [weak self] result in
				guard let self else { return }
				switch result {
					case .success(let p):
						self.cachedProducts[placement] = p
					case .failure:
						break
				}
			})
		}
	}

	/// The one paywall-loading path — `configure` and `refreshPaywalls()` both funnel through
	/// this instead of calling `Adapty.getPaywall` themselves. On failure it keeps retrying
	/// itself, spaced out with exponential backoff per placement, until it succeeds — the
	/// approved schema says loading continues until it succeeds. Each scheduled retry re-checks
	/// `paywalls[placement]` right before it fires, so a retry queued before an explicit
	/// `refreshPaywalls()` call already succeeded does not turn into a stray extra SDK call.
	private func loadPaywall(placement: String) {
		Adapty.getPaywall(placementId: placement, { [weak self] result in
			guard let self else { return }
			switch result {
				case .success(let paywall):
					self.paywallBackoff[placement] = nil
					self.paywalls[placement] = paywall
					self.fetchProductsForPaywall(placement: placement)
				case .failure:
					let delay = self.paywallBackoff[placement] ?? Self.initialPaywallBackoff
					self.paywallBackoff[placement] = min(delay * 2, Self.maxPaywallBackoff)
					// At most one retry in flight per placement. Without this, every
					// `refreshPaywalls()` on a still-broken placement starts its own independent
					// chain: a session that returns to the foreground twenty times ends up with
					// twenty of them hammering the SDK in parallel, which is exactly the spin the
					// backoff exists to prevent.
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

	func hasPaywall(placement: String) -> Bool {
		return paywalls[placement] != nil
	}

	/// Re-attempts every configured placement that is still missing a paywall. Fired by the
	/// composition root on `UIApplication.didBecomeActiveNotification` — this file stays UIKit-free,
	/// so the trigger itself lives in `IntegrationKit.swift`.
	///
	/// Returning to the foreground is a fresh signal, so this does not wait out a placement's
	/// pending backoff: it resets that placement's delay back to `initialPaywallBackoff` and calls
	/// `loadPaywall` immediately. It does not stack a second retry chain on top of the pending one
	/// — `loadPaywall` keeps at most one scheduled retry per placement.
	func refreshPaywalls() {
		for placement in configuredPlacements where paywalls[placement] == nil {
			paywallBackoff[placement] = Self.initialPaywallBackoff
			loadPaywall(placement: placement)
		}
	}

	func hasProductsForPaywall(placement: String, id: String) -> Bool {
		return cachedProducts[placement]?.contains(where: {$0.vendorProductId == id}) ?? false
	}

	func hasProductsForPaywall(placement: String) -> Bool {
		return cachedProducts[placement]?.first != nil
	}

	func getRemoteValue<Type>(placement: String, key: String) -> Type? {
		if let id = paywalls[placement]?.remoteConfig?[key] as? Type {
			return id
		}
		return nil
	}

	func logPaywallOpen(placement: String) {
		if let paywall = paywalls[placement] {
			Adapty.logShowPaywall(paywall)
		}
	}

	func logOnboardingOpen(step: Int) {
		Adapty.logShowOnboarding(name: "onboarding_\(step)", screenName: nil, screenOrder: UInt(step))
	}

	func updateAttribution(attribution: [AnyHashable: Any]) {
		Adapty.updateAttribution(attribution, source: .adjust)
	}

	func updateAppsFlyerAttribution(_ data: [AnyHashable: Any], networkUserId: String?) {
		Adapty.updateAttribution(data, source: .appsflyer, networkUserId: networkUserId) { error in
			if let error {
				debugLog("[AppsFlyer→Adapty] updateAttribution failed: \(error)")
			} else {
				debugLog("[AppsFlyer→Adapty] updateAttribution success")
			}
		}
	}

	func buyProduct(placement: String, id: String, completion: ((AdaptyPurchaseResult) -> Void)?) {
		if let product = cachedProducts[placement]?.first(where: { $0.vendorProductId == id }) {
			Adapty.makePurchase(product: product) { result in
				switch result {
					case .success:
						self.onPurchaseSucceeded?()
						completion?(.success)
					case let .failure(error):
						debugLog("Adapty error: \(error.localizedDescription)")
						switch error.adaptyErrorCode {
							case .paymentCancelled:
								completion?(.cancelled)
							case .productRequestFailed, .serverError, .unknown, .productPurchaseFailed:
								completion?(.retryWithStoreKit)
							default:
								completion?(.failed)
						}
				}
			}
		} else {
			// Adapty never cached this product — its paywall was never loaded, so Adapty could
			// not serve this purchase at all. That is exactly the case the StoreKit fallback
			// exists for.
			completion?(.retryWithStoreKit)
		}
	}

	func integrateFirebase(appInstanceId: String) {
		let builder = AdaptyProfileParameters.Builder()
			.with(firebaseAppInstanceId: appInstanceId)
		Adapty.updateProfile(params: builder.build()) { error in
			debugLog("ERRORRR \(error)")
		}
	}

	func integrateFacebook(id: String) {
		let builder = AdaptyProfileParameters.Builder()
			.with(facebookAnonymousId: id)

		Adapty.updateProfile(params: builder.build()) { error in
			debugLog("ERRORRR ADAPTY FACEBOOK \(error)")
		}
	}

	/// Puts our own device id on the Adapty side so an Adapty event and an analytics event
	/// describe the same user. The caller's analytics tracker gets the same id at its own
	/// configure() time, so events fired before Adapty finishes activating already carry it.
	private func linkAmplitudeUserId(deviceId: String, analytics: AnalyticsTracking) {
		let builder = AdaptyProfileParameters.Builder()
			.with(amplitudeUserId: deviceId)
			.with(amplitudeDeviceId: analytics.deviceId ?? "")
		Adapty.updateProfile(params: builder.build()) { error in
			debugLog("ADAPTY AMPLITUDE LINK \(error == nil ? "ok" : "error")")
		}
	}

	func updateAppTrackingTransparencyStatus(_ status: ATTrackingManager.AuthorizationStatus) {
		let builder = AdaptyProfileParameters.Builder()
			.with(appTrackingTransparencyStatus: status)
		Adapty.updateProfile(params: builder.build()) { error in
			debugLog("ADAPTY ATT STATUS \(error == nil ? "ok" : "error")")
		}
	}

	// MARK: - AdaptyPremiumProviding: async over Adapty's own callbacks.
	// Every wrapper here goes through `withSingleResume`, never `withCheckedContinuation`
	// directly — see the note there on Adapty calling a completion twice.

	/// `nil` means Adapty did not answer — never "no premium".
	///
	/// On the SDK side (2.10.x) `getProfile` performs a network fetch and falls back to the
	/// stored profile when that request fails, so `.failure` here means the SDK is not activated
	/// or the profile was swapped mid-flight — being offline still answers, from the cache.
	func profile() async -> AdaptyProfile? {
		await withSingleResume { resume in
			Adapty.getProfile { result in
				switch result {
					case .success(let profile):
						resume(profile)
					case .failure:
						resume(nil)
				}
			}
		}
	}

	/// Products of a placement, already wrapped so the caller never sees an Adapty type.
	/// Uses the cache `configure` filled; fetches only when it is still empty, which is the
	/// normal case for a paywall opened right after launch.
	func products(placement: String) async -> [PremiumProduct] {
		if let cached = cachedProducts[placement], !cached.isEmpty {
			return cached.map(PremiumProduct.init(product:))
		}
		guard let paywall = paywalls[placement] else { return [] }
		let fetched: [AdaptyPaywallProduct] = await withSingleResume { resume in
			Adapty.getPaywallProducts(paywall: paywall, { result in
				switch result {
					case .success(let products):
						resume(products)
					case .failure:
						resume([])
				}
			})
		}
		// Same cache `fetchProductsForPaywall` writes; Adapty was activated with
		// `dispatchQueue: .main`, so both writers land on the main queue.
		cachedProducts[placement] = fetched
		return fetched.map(PremiumProduct.init(product:))
	}

	func buy(productId: String, placement: String) async -> AdaptyPurchaseResult {
		await withSingleResume { resume in
			self.buyProduct(placement: placement, id: productId) { resume($0) }
		}
	}

	func remoteValue<T>(placement: String, key: String) -> T? {
		getRemoteValue(placement: placement, key: key)
	}

	/// Asks Adapty to upload the local receipt to its backend and refresh the profile. Called by
	/// `PremiumService` right after a StoreKit fallback purchase succeeds, to close the window the
	/// local-purchase mark exists to cover.
	func syncReceipt() {
		Adapty.restorePurchases { _ in }
	}
}

extension AdaptyService: AdaptyDelegate {
	/// Adapty pushes this on activation, on any profile change, and after a dashboard grant.
	func didLoadLatestProfile(_ profile: AdaptyProfile) {
		premiumObserver?(profile)
	}
}
