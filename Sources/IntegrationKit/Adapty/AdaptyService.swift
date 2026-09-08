//
//  AdaptyService.swift
//  IntegrationKit
//

import AppTrackingTransparency
import Foundation
import Adapty
import AdaptyUI

final class AdaptyService: AdaptyServicing, AdaptyPremiumProviding {

	private var paywalls: [String: AdaptyPaywall] = [:] {
		didSet {
			self.observer?()
		}
	}

	private var cachedProducts: [String: [AdaptyPaywallProduct]] = [:]

	var observer: (() -> Void)?
	/// Fires whenever Adapty pushes a fresh profile (activation, any profile change). Callers
	/// derive their own premium decision from `AdaptyProfile.accessLevels`.
	var premiumObserver: ((AdaptyProfile) -> Void)?
	/// Fires right after a purchase succeeds, before Adapty's own profile push round-trips back
	/// through `premiumObserver` — lets a caller apply an optimistic premium state immediately.
	var onPurchaseSucceeded: (() -> Void)?

	init() {}

	func configure(apiKey: String, customerUserId: String, sessionsCounter: Int, placements: [String], analytics: AnalyticsTracking) {
		// Set before activate so the very first profile push is not missed.
		Adapty.delegate = self
		Adapty.activate(apiKey, observerMode: false, customerUserId: customerUserId, dispatchQueue: .main, { _ in
			self.linkAmplitudeUserId(deviceId: customerUserId, analytics: analytics)
			let dateFormatter = DateFormatter()
			dateFormatter.dateFormat = "dd-MM-yyyy"
			self.setProfileValue(value: dateFormatter.string(from: .now), key: "lastUsedDay")
			self.setProfileValue(value: sessionsCounter.description, key: "launchSession")
			for value in placements {
				Adapty.getPaywall(placementId: value, { result in
					switch result {
						case .success(let paywall):
							self.paywalls[value] = paywall
							self.fetchProductsForPaywall(placement: value)
						case .failure:
							break
					}
				})
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

	func hasPaywall(placement: String) -> Bool {
		return paywalls[placement] != nil
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

	func getAbValue(placement: String) -> Int? {
		if let id = paywalls[placement]?.remoteConfig?["id"] as? Int {
			return id
		}
		return nil
	}
	func getBoolValue(placement: String, key: String) -> Bool {
		if let id = paywalls[placement]?.remoteConfig?[key] as? Bool {
			return id
		}
		return false
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
			completion?(.failed)
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
}

extension AdaptyService: AdaptyDelegate {
	/// Adapty pushes this on activation, on any profile change, and after a dashboard grant.
	func didLoadLatestProfile(_ profile: AdaptyProfile) {
		premiumObserver?(profile)
	}
}
