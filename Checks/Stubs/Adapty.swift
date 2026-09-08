//
//  Adapty.swift
//  IntegrationKit — Checks/Stubs
//
//  Stand-in for the `Adapty` SDK namespace (2.10.x). Compiled into a module called `Adapty`
//  alongside the other files in this folder, so `AdaptyService` builds and runs outside Xcode with
//  its `import Adapty` untouched.
//
//  Every method reads its answer from a static var and counts its own calls — same idea as
//  `SwiftyStoreKit`'s stub, because the real SDK is a namespace of static calls too, never an
//  injected instance. `getPaywallResults` is a queue: each call to `getPaywall` consumes the next
//  entry and then holds on the last one, so a check only has to queue as many answers as it cares
//  about (one entry for "always fails", two for "fails once then succeeds"). `reset()` clears
//  every answer and counter; call it at the top of each row so one row's setup cannot leak into
//  the next.
//

import Foundation

public enum Adapty {
	public static var delegate: AdaptyDelegate?

	/// What `activate`'s completion hands back. `nil` (success) by default.
	public static var activateError: Error?

	public static var getPaywallResults: [Result<AdaptyPaywall, AdaptyError>] = [.failure(AdaptyError(.unknown))]
	public static private(set) var getPaywallCallCount = 0

	public static var getPaywallProductsResult: Result<[AdaptyPaywallProduct], AdaptyError> = .success([])

	public static var getProfileResult: Result<AdaptyProfile, AdaptyError> = .failure(AdaptyError(.unknown))

	public static var makePurchaseResult: Result<Void, AdaptyError> = .failure(AdaptyError(.unknown))

	public static var restorePurchasesResult: Result<AdaptyProfile, AdaptyError> = .failure(AdaptyError(.unknown))
	public static private(set) var restorePurchasesCallCount = 0

	public static private(set) var logShowPaywallCount = 0
	public static private(set) var logShowOnboardingCount = 0

	public static func reset() {
		delegate = nil
		activateError = nil
		getPaywallResults = [.failure(AdaptyError(.unknown))]
		getPaywallCallCount = 0
		getPaywallProductsResult = .success([])
		getProfileResult = .failure(AdaptyError(.unknown))
		makePurchaseResult = .failure(AdaptyError(.unknown))
		restorePurchasesResult = .failure(AdaptyError(.unknown))
		restorePurchasesCallCount = 0
		logShowPaywallCount = 0
		logShowOnboardingCount = 0
	}

	public static func activate(_ apiKey: String, observerMode: Bool, customerUserId: String, dispatchQueue: DispatchQueue, _ completion: @escaping (Error?) -> Void) {
		completion(activateError)
	}

	/// Consumes `getPaywallResults[min(callCount, count - 1)]` — walks the queue forward one entry
	/// per call and then repeats the last entry forever, so a check never has to pad the queue out
	/// to however many calls it thinks might happen.
	public static func getPaywall(placementId: String, _ completion: @escaping (Result<AdaptyPaywall, AdaptyError>) -> Void) {
		let index = min(getPaywallCallCount, getPaywallResults.count - 1)
		getPaywallCallCount += 1
		completion(getPaywallResults[index])
	}

	public static func getPaywallProducts(paywall: AdaptyPaywall, _ completion: @escaping (Result<[AdaptyPaywallProduct], AdaptyError>) -> Void) {
		completion(getPaywallProductsResult)
	}

	public static func getProfile(_ completion: @escaping (Result<AdaptyProfile, AdaptyError>) -> Void) {
		completion(getProfileResult)
	}

	public static func makePurchase(product: AdaptyPaywallProduct, _ completion: @escaping (Result<Void, AdaptyError>) -> Void) {
		completion(makePurchaseResult)
	}

	public static func logShowPaywall(_ paywall: AdaptyPaywall) {
		logShowPaywallCount += 1
	}

	public static func logShowOnboarding(name: String, screenName: String?, screenOrder: UInt) {
		logShowOnboardingCount += 1
	}

	public static func updateAttribution(_ attribution: [AnyHashable: Any], source: AdaptyAttributionSource) {
	}

	public static func updateAttribution(_ data: [AnyHashable: Any], source: AdaptyAttributionSource, networkUserId: String?, _ completion: @escaping (Error?) -> Void) {
		completion(nil)
	}

	public static func updateProfile(params: AdaptyProfileParameters, _ completion: @escaping (Error?) -> Void) {
		completion(nil)
	}

	public static func restorePurchases(_ completion: @escaping (Result<AdaptyProfile, AdaptyError>) -> Void) {
		restorePurchasesCallCount += 1
		completion(restorePurchasesResult)
	}
}
