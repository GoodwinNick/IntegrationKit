//
//  Adapty.swift
//  IntegrationKit — Checks/Stubs
//
//  Stand-in for the `Adapty` SDK namespace (2.10.x). Compiled into a module called `Adapty`
//  alongside the other files in this folder, so `AdaptyService` builds and runs outside Xcode with
//  its `import Adapty` untouched.
//
//  Every method reads its answer from a static var and journals what it was given — same idea as
//  `SwiftyStoreKit`'s stub, because the real SDK is a namespace of static calls too, never an
//  injected instance.
//
//  Three things this stub does that a naive one cannot, and every one of them is required by a row
//  of the approved schemas:
//
//  * **Queued answers.** `getPaywallResults` and `activateErrors` walk forward one entry per call
//    and then repeat the last one forever, so a check queues only as many answers as it cares
//    about ("fails once then succeeds", "second activation is rejected").
//  * **Holding.** `holdGetPaywall`, `holdUpdateProfile`, `holdGetProfile` and `holdMakePurchase`
//    capture the completion instead of calling it. That is the SDK behaviour behind AD-04 row 1,
//    AD-05 row 1 and AD-06 row 2 — a completion that never arrives — and it is unreproducible with
//    an error result, because an error IS an answer.
//  * **Journals.** `updateProfileJournal` and `updateAttributionJournal` keep what actually reached
//    the SDK. Several rows assert that a value did NOT reach it, which a call counter cannot show.
//
//  `reset()` clears every answer, journal and counter; call it at the top of each row so one row's
//  setup cannot leak into the next.
//

import Foundation

public enum Adapty {
	public static var delegate: AdaptyDelegate?

	/// What `activate`'s completion hands back, one entry per call. `nil` (success) by default.
	/// Two entries `[nil, AdaptyError(.activateOnceError)]` is the double-`configure` case.
	public static var activateErrors: [Error?] = [nil]
	public static private(set) var activateCallCount = 0
	public static private(set) var lastActivatedKey: String?

	public static var getPaywallResults: [Result<AdaptyPaywall, AdaptyError>] = [.failure(AdaptyError(.unknown))]
	public static private(set) var getPaywallCallCount = 0
	/// Capture `getPaywall` completions instead of answering. The dedup rows need a request that is
	/// genuinely still in flight when the next call arrives.
	public static var holdGetPaywall = false
	public static private(set) var heldGetPaywalls: [(placementId: String, completion: (Result<AdaptyPaywall, AdaptyError>) -> Void)] = []

	public static var getPaywallProductsResult: Result<[AdaptyPaywallProduct], AdaptyError> = .success([])
	public static private(set) var getPaywallProductsCallCount = 0

	public static var getProfileResult: Result<AdaptyProfile, AdaptyError> = .failure(AdaptyError(.unknown))
	public static var holdGetProfile = false
	/// Held completions are RETAINED, never dropped — that is what the real SDK does with them
	/// (`SK1QueueManager` leaves the handler in its dictionary and `getProfileManager` leaves it in
	/// its bucket). Dropping them instead would make the Swift runtime report a leaked continuation
	/// for behaviour the schemas describe as normal.
	public static private(set) var heldGetProfiles: [(Result<AdaptyProfile, AdaptyError>) -> Void] = []

	public static var makePurchaseResult: Result<Void, AdaptyError> = .failure(AdaptyError(.unknown))
	public static var holdMakePurchase = false
	public static private(set) var heldPurchases: [(Result<Void, AdaptyError>) -> Void] = []

	public static var holdUpdateProfileHandlers: [(Error?) -> Void] = []

	public static var restorePurchasesResult: Result<AdaptyProfile, AdaptyError> = .failure(AdaptyError(.unknown))
	public static private(set) var restorePurchasesCallCount = 0

	/// What `logShowPaywall`'s completion hands back.
	public static var logShowPaywallError: Error?
	public static private(set) var logShowPaywallCount = 0

	/// What `logShowOnboarding`'s completion hands back.
	public static var logShowOnboardingError: Error?
	public static private(set) var logShowOnboardingCount = 0
	/// The arguments of the last onboarding event that reached the SDK. AD-07 row 3 asserts on the
	/// NAME and the ORDER, not on the fact that a call happened: `onboarding_1` at `screenOrder` 1
	/// is the shape the dashboard funnel is built on, and a counter cannot tell it apart from an
	/// `onboarding_0` the SDK would have thrown away.
	public static private(set) var lastOnboardingName: String?
	public static private(set) var lastOnboardingScreenName: String?
	public static private(set) var lastOnboardingScreenOrder: UInt?

	public static var updateProfileError: Error?
	public static var holdUpdateProfile = false
	/// Every profile write that actually reached the SDK, in order.
	public static private(set) var updateProfileJournal: [AdaptyProfileParameters] = []

	public static var updateAttributionError: Error?
	/// Every attribution write that actually reached the SDK, in order.
	public static private(set) var updateAttributionJournal: [(source: AdaptyAttributionSource, networkUserId: String?)] = []

	public static func reset() {
		delegate = nil
		activateErrors = [nil]
		activateCallCount = 0
		lastActivatedKey = nil
		getPaywallResults = [.failure(AdaptyError(.unknown))]
		getPaywallCallCount = 0
		holdGetPaywall = false
		heldGetPaywalls = []
		getPaywallProductsResult = .success([])
		getPaywallProductsCallCount = 0
		getProfileResult = .failure(AdaptyError(.unknown))
		holdGetProfile = false
		makePurchaseResult = .failure(AdaptyError(.unknown))
		holdMakePurchase = false
		holdUpdateProfileHandlers = []
		// `heldGetProfiles` and `heldPurchases` are NOT cleared: the SDK keeps a handler it never
		// called for the life of the process, and releasing them here would hand the Swift runtime a
		// deallocated continuation to complain about.
		restorePurchasesResult = .failure(AdaptyError(.unknown))
		restorePurchasesCallCount = 0
		logShowPaywallError = nil
		logShowPaywallCount = 0
		logShowOnboardingError = nil
		logShowOnboardingCount = 0
		lastOnboardingName = nil
		lastOnboardingScreenName = nil
		lastOnboardingScreenOrder = nil
		updateProfileError = nil
		holdUpdateProfile = false
		updateProfileJournal = []
		updateAttributionError = nil
		updateAttributionJournal = []
		AdaptyPaywall.parseCount = 0
	}

	/// Answers the oldest held `getPaywall`, so a check can let an in-flight request finish after it
	/// has proven the second one was suppressed.
	public static func releaseHeldPaywall(_ result: Result<AdaptyPaywall, AdaptyError>) {
		guard !heldGetPaywalls.isEmpty else { return }
		let held = heldGetPaywalls.removeFirst()
		held.completion(result)
	}

	public static func activate(_ apiKey: String, observerMode: Bool, customerUserId: String, dispatchQueue: DispatchQueue, _ completion: @escaping (Error?) -> Void) {
		let index = min(activateCallCount, activateErrors.count - 1)
		activateCallCount += 1
		lastActivatedKey = apiKey
		completion(activateErrors[index])
	}

	/// Consumes `getPaywallResults[min(callCount, count - 1)]` — walks the queue forward one entry
	/// per call and then repeats the last entry forever, so a check never has to pad the queue out
	/// to however many calls it thinks might happen.
	public static func getPaywall(placementId: String, _ completion: @escaping (Result<AdaptyPaywall, AdaptyError>) -> Void) {
		let index = min(getPaywallCallCount, getPaywallResults.count - 1)
		getPaywallCallCount += 1
		guard !holdGetPaywall else {
			heldGetPaywalls.append((placementId: placementId, completion: completion))
			return
		}
		completion(getPaywallResults[index])
	}

	public static func getPaywallProducts(paywall: AdaptyPaywall, _ completion: @escaping (Result<[AdaptyPaywallProduct], AdaptyError>) -> Void) {
		getPaywallProductsCallCount += 1
		completion(getPaywallProductsResult)
	}

	public static func getProfile(_ completion: @escaping (Result<AdaptyProfile, AdaptyError>) -> Void) {
		guard !holdGetProfile else {
			heldGetProfiles.append(completion)
			return
		}
		completion(getProfileResult)
	}

	public static func makePurchase(product: AdaptyPaywallProduct, _ completion: @escaping (Result<Void, AdaptyError>) -> Void) {
		guard !holdMakePurchase else {
			heldPurchases.append(completion)
			return
		}
		completion(makePurchaseResult)
	}

	public static func logShowPaywall(_ paywall: AdaptyPaywall, _ completion: ((Error?) -> Void)? = nil) {
		logShowPaywallCount += 1
		completion?(logShowPaywallError)
	}

	/// Counts and journals whatever it is given — the SDK's own `screenOrder > 0` guard is NOT
	/// reproduced here on purpose. That guard is the SDK's; the row this stub serves is about OUR
	/// guard, and a stub that refused a zero itself would leave the counter at zero either way, so a
	/// missing guard in `AdaptyService` would read exactly like a working one.
	public static func logShowOnboarding(name: String?, screenName: String?, screenOrder: UInt, _ completion: ((Error?) -> Void)? = nil) {
		logShowOnboardingCount += 1
		lastOnboardingName = name
		lastOnboardingScreenName = screenName
		lastOnboardingScreenOrder = screenOrder
		completion?(logShowOnboardingError)
	}

	public static func updateAttribution(_ attribution: [AnyHashable: Any], source: AdaptyAttributionSource) {
		updateAttributionJournal.append((source: source, networkUserId: nil))
	}

	public static func updateAttribution(_ data: [AnyHashable: Any], source: AdaptyAttributionSource, networkUserId: String?, _ completion: @escaping (Error?) -> Void) {
		if updateAttributionError == nil {
			updateAttributionJournal.append((source: source, networkUserId: networkUserId))
		}
		completion(updateAttributionError)
	}

	public static func updateProfile(params: AdaptyProfileParameters, _ completion: @escaping (Error?) -> Void) {
		guard !holdUpdateProfile else {
			holdUpdateProfileHandlers.append(completion)
			return
		}
		if updateProfileError == nil {
			updateProfileJournal.append(params)
		}
		completion(updateProfileError)
	}

	public static func restorePurchases(_ completion: @escaping (Result<AdaptyProfile, AdaptyError>) -> Void) {
		restorePurchasesCallCount += 1
		completion(restorePurchasesResult)
	}
}
