//
//  AdaptyService.swift
//  IntegrationKit
//

import AppTrackingTransparency
import Foundation
import Adapty
import AdaptyUI

public final class AdaptyService: AdaptyServicing {

	private var paywalls: [String: AdaptyPaywall] = [:] {
		didSet {
			self.observer?()
		}
	}

	private var products: [String: [AdaptyPaywallProduct]] = [:]

	public var observer: (() -> Void)?
	/// Fires whenever Adapty pushes a fresh profile (activation, any profile change). Callers
	/// derive their own premium decision from `AdaptyProfile.accessLevels`.
	public var premiumObserver: ((AdaptyProfile) -> Void)?
	/// Fires right after a purchase succeeds, before Adapty's own profile push round-trips back
	/// through `premiumObserver` — lets a caller apply an optimistic premium state immediately.
	public var onPurchaseSucceeded: (() -> Void)?

	public init() {}

	public func configure(apiKey: String, customerUserId: String, sessionsCounter: Int, placements: [String], analytics: AnalyticsTracking) {
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

	public func setProfileValue(value: String, key: String) {
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
						self.products[placement] = p
					case .failure:
						break
				}
			})
		}
	}

	public func hasPaywall(placement: String) -> Bool {
		return paywalls[placement] != nil
	}

	public func hasProductsForPaywall(placement: String, id: String) -> Bool {
		return products[placement]?.contains(where: {$0.vendorProductId == id}) ?? false
	}

	public func hasProductsForPaywall(placement: String) -> Bool {
		return products[placement]?.first != nil
	}

	public func getRemoteValue<Type>(placement: String, key: String) -> Type? {
		if let id = paywalls[placement]?.remoteConfig?[key] as? Type {
			return id
		}
		return nil
	}

	public func getAbValue(placement: String) -> Int? {
		if let id = paywalls[placement]?.remoteConfig?["id"] as? Int {
			return id
		}
		return nil
	}
	public func getBoolValue(placement: String, key: String) -> Bool {
		if let id = paywalls[placement]?.remoteConfig?[key] as? Bool {
			return id
		}
		return false
	}

	public func logPaywallOpen(placement: String) {
		if let paywall = paywalls[placement] {
			Adapty.logShowPaywall(paywall)
		}
	}

	public func logOnboardingOpen(step: Int) {
		Adapty.logShowOnboarding(name: "onboarding_\(step)", screenName: nil, screenOrder: UInt(step))
	}

	public func updateAttribution(attribution: [AnyHashable: Any]) {
		Adapty.updateAttribution(attribution, source: .adjust)
	}

	public func updateAppsFlyerAttribution(_ data: [AnyHashable: Any], networkUserId: String?) {
		Adapty.updateAttribution(data, source: .appsflyer, networkUserId: networkUserId) { error in
			if let error {
				debugLog("[AppsFlyer→Adapty] updateAttribution failed: \(error)")
			} else {
				debugLog("[AppsFlyer→Adapty] updateAttribution success")
			}
		}
	}

	public func buyProduct(placement: String, id: String, completion: ((AdaptyPurchaseResult) -> Void)?) {
		if let product = products[placement]?.first(where: { $0.vendorProductId == id }) {
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

	public func integrateFirebase(appInstanceId: String) {
		let builder = AdaptyProfileParameters.Builder()
			.with(firebaseAppInstanceId: appInstanceId)
		Adapty.updateProfile(params: builder.build()) { error in
			debugLog("ERRORRR \(error)")
		}
	}

	public func integrateFacebook(id: String) {
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

	public func updateAppTrackingTransparencyStatus(_ status: ATTrackingManager.AuthorizationStatus) {
		let builder = AdaptyProfileParameters.Builder()
			.with(appTrackingTransparencyStatus: status)
		Adapty.updateProfile(params: builder.build()) { error in
			debugLog("ADAPTY ATT STATUS \(error == nil ? "ok" : "error")")
		}
	}

	public func refreshPremium() {
		Adapty.getProfile { [weak self] result in
			guard let self, case .success(let profile) = result else { return }
			self.premiumObserver?(profile)
		}
	}
}

extension AdaptyService: AdaptyDelegate {
	/// Adapty pushes this on activation, on any profile change, and after a dashboard grant.
	public func didLoadLatestProfile(_ profile: AdaptyProfile) {
		premiumObserver?(profile)
	}
}
