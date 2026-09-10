//
//  Adapty.swift
//  IntegrationKit — Checks/Stubs
//
//  Stand-in for the `Adapty` SDK namespace (4.1.3). Compiled into a module called `Adapty` alongside
//  the other files in this folder, so `AdaptyService` builds and runs outside Xcode with its
//  `import Adapty` untouched.
//
//  Every method reads its answer from a static var and journals what it was given — same idea as
//  `SwiftyStoreKit`'s stub, because the real SDK is a namespace of static calls too, never an
//  injected instance.
//
//  What this stub does that a naive one cannot, and every one of them is required by a row of the
//  approved schemas:
//
//  * **Queued answers.** `getFlowResults` and `activateErrors` walk forward one entry per call and
//    then repeat the last one forever, so a check queues only as many answers as it cares about
//    ("fails once then succeeds", "second activation is rejected").
//  * **Holding.** `holdGetFlow`, `holdUpdateProfile`, `holdGetProfile` and `holdMakePurchase`
//    capture the completion instead of calling it. That is the SDK behaviour behind AD-04 row 1,
//    AD-05 row 1 and AD-06 row 2 — a completion that never arrives — and it is unreproducible with
//    an error result, because an error IS an answer.
//  * **Never-finishing activation.** `activationNeverFinishes` is new in this rewrite and it is the
//    whole of AD-06 row 9. On 2.10.x a call made before `activate` finished failed immediately with
//    `.notActivated`, and that error is what fed the retry queue. On 4.1.3
//    `Adapty.activatedSDK` AWAITS an activation that is in flight (`Adapty+Shared.swift:32-44`) and
//    only throws `.notActivated` when none was ever started (`:41`). So a slow activation no longer
//    produces an error to retry on — it produces a call that hangs. The queue's feeder is gone.
//  * **Journals.** `updateProfileJournal`, `externalAttributionJournal`,
//    `integrationIdentifierJournal` and `logShowFlowJournal` keep what actually reached the SDK.
//    Several rows assert that a value did NOT reach it, which a call counter cannot show.
//  * **The synchronous attribution failure.** `updateExternalAttribution` serialises the payload
//    BEFORE it does anything asynchronous, and answers `.wrongParam` on the caller's own stack if it
//    will not serialise (`Adapty+Completion.swift:137-144`). AD-06 row 11 is entirely about that
//    "before": a retry queued from inside that completion is queued into a pass that has not
//    finished draining.
//
//  Completions are plain `@escaping`, not `@Sendable` as upstream. Sendability of what the package
//  captures is proven by `buildhost-check.sh`, which compiles `Sources/` against the REAL SDKs;
//  duplicating the constraint here would only add `@unchecked` noise to the checks' own fixtures.
//
//  `reset()` clears every answer, journal and counter; call it at the top of each row so one row's
//  setup cannot leak into the next.
//

import Foundation

public enum Adapty {
	/// Upstream this is a `nonisolated(unsafe) static var` holding a STRONG reference
	/// (`AdaptyDelegate.swift:39`) — same as here. 2.10.x's stub was strong too, but the service kept
	/// its own `Self.retained = self` on top of it, from back when the reference was believed weak.
	public static var delegate: AdaptyDelegate?

	// MARK: - Activation

	/// What `activate`'s completion hands back, one entry per call. `nil` (success) by default.
	/// Two entries `[nil, AdaptyError(.activateOnceError)]` is the double-`configure` case.
	public static var activateErrors: [AdaptyError?] = [nil]
	public static private(set) var activateCallCount = 0
	/// The configuration object the service built. Everything `configure` decides — the key, observer
	/// mode, whether Adapty Attribution was switched on, which queue callbacks land on — is readable
	/// from here and nowhere else.
	public static private(set) var lastConfiguration: AdaptyConfiguration?

	/// See the file comment: activation starts and never completes, and every call that would wait
	/// for it waits forever. Set it BEFORE `configure`.
	public static var activationNeverFinishes = false
	/// Answers withheld by `activationNeverFinishes`, kept alive rather than dropped — the real SDK
	/// leaves such a continuation parked for the life of the process, and releasing it here would
	/// hand the Swift runtime a deallocated continuation to complain about.
	public static private(set) var heldByActivation: [() -> Void] = []

	// MARK: - Placements

	public static var getFlowResults: [Result<AdaptyFlow, AdaptyError>] = [.failure(AdaptyError(.unknown))]
	public static private(set) var getFlowCallCount = 0
	/// Capture `getFlow` completions instead of answering. The dedup rows need a request that is
	/// genuinely still in flight when the next call arrives.
	public static var holdGetFlow = false
	public static private(set) var heldGetFlows: [(placementId: String, completion: (Result<AdaptyFlow, AdaptyError>) -> Void)] = []

	public static var getPaywallProductsResult: Result<[AdaptyPaywallProduct], AdaptyError> = .success([])
	public static private(set) var getPaywallProductsCallCount = 0

	/// Every flow whose show-event reached the SDK, by `variationId`. AD-07: the dashboard funnel is
	/// built on which variation was shown, so a counter cannot stand in for this.
	public static var logShowFlowError: AdaptyError?
	public static private(set) var logShowFlowJournal: [String] = []

	// MARK: - Profile

	public static var getProfileResult: Result<AdaptyProfile, AdaptyError> = .failure(AdaptyError(.unknown))
	public static var holdGetProfile = false
	/// Held completions are RETAINED, never dropped — see `heldByActivation`.
	public static private(set) var heldGetProfiles: [(Result<AdaptyProfile, AdaptyError>) -> Void] = []

	public static var updateProfileError: AdaptyError?
	public static var holdUpdateProfile = false
	public static private(set) var heldUpdateProfiles: [(AdaptyError?) -> Void] = []
	/// Every profile write that actually reached the SDK, in order.
	public static private(set) var updateProfileJournal: [AdaptyProfileParameters] = []

	// MARK: - Attribution (two halves, AD-06 row 10)

	public static var externalAttributionError: AdaptyError?
	public static private(set) var externalAttributionJournal: [(provider: AdaptyExternalAttributionProvider, attribution: [AnyHashable: Any])] = []

	public static var integrationIdentifierError: AdaptyError?
	public static private(set) var integrationIdentifierJournal: [AdaptyIntegrationIdentifier] = []

	// MARK: - Purchases

	public static var makePurchaseResult: Result<AdaptyPurchaseResult, AdaptyError> = .failure(AdaptyError(.unknown))
	public static var holdMakePurchase = false
	public static private(set) var heldPurchases: [(Result<AdaptyPurchaseResult, AdaptyError>) -> Void] = []

	public static var restorePurchasesResult: Result<AdaptyProfile, AdaptyError> = .failure(AdaptyError(.unknown))
	public static private(set) var restorePurchasesCallCount = 0

	/// How many times `AdaptyDelegate`'s DEFAULT `didReceivePromotedPurchase` ran — that default
	/// starts a purchase nobody asked for (`AdaptyDelegate.swift:24-29`). A service that overrides
	/// the method leaves this at zero; one that merely conforms does not.
	public static private(set) var promotedPurchaseAutoBuyCount = 0
	public static private(set) var promotedPurchaseAutoBuyProductIds: [String] = []

	public static func recordPromotedPurchaseAutoBuy(_ product: AdaptyPromotedProduct) {
		promotedPurchaseAutoBuyCount += 1
		promotedPurchaseAutoBuyProductIds.append(product.vendorProductId)
	}

	// MARK: - Harness control

	public static func reset() {
		delegate = nil
		activateErrors = [nil]
		activateCallCount = 0
		lastConfiguration = nil
		activationNeverFinishes = false
		getFlowResults = [.failure(AdaptyError(.unknown))]
		getFlowCallCount = 0
		holdGetFlow = false
		heldGetFlows = []
		getPaywallProductsResult = .success([])
		getPaywallProductsCallCount = 0
		logShowFlowError = nil
		logShowFlowJournal = []
		getProfileResult = .failure(AdaptyError(.unknown))
		holdGetProfile = false
		updateProfileError = nil
		holdUpdateProfile = false
		updateProfileJournal = []
		externalAttributionError = nil
		externalAttributionJournal = []
		integrationIdentifierError = nil
		integrationIdentifierJournal = []
		makePurchaseResult = .failure(AdaptyError(.unknown))
		holdMakePurchase = false
		restorePurchasesResult = .failure(AdaptyError(.unknown))
		restorePurchasesCallCount = 0
		promotedPurchaseAutoBuyCount = 0
		promotedPurchaseAutoBuyProductIds = []
		// `heldGetProfiles`, `heldPurchases`, `heldUpdateProfiles` and `heldByActivation` are NOT
		// cleared: the SDK keeps a handler it never called for the life of the process.
		AdaptyRemoteConfig.parseCount = 0
		AdaptyUnfinishedTransaction.resetFinishJournal()
	}

	/// Answers the oldest held `getFlow`, so a check can let an in-flight request finish after it has
	/// proven the second one was suppressed.
	public static func releaseHeldFlow(_ result: Result<AdaptyFlow, AdaptyError>) {
		guard !heldGetFlows.isEmpty else { return }
		let held = heldGetFlows.removeFirst()
		held.completion(result)
	}

	/// Lets a never-finishing activation finally finish, and delivers everything that piled up behind
	/// it. A check uses this to prove what the service does with answers that arrive minutes late.
	public static func releaseActivation() {
		activationNeverFinishes = false
		let pending = heldByActivation
		heldByActivation = []
		for deliver in pending { deliver() }
	}

	/// Parks `deliver` when activation is hanging. Returns `true` when the call was parked.
	private static func parkedBehindActivation(_ deliver: @escaping () -> Void) -> Bool {
		guard activationNeverFinishes else { return false }
		heldByActivation.append(deliver)
		return true
	}

	// MARK: - SDK surface

	public static func activate(with configuration: AdaptyConfiguration, _ completion: ((AdaptyError?) -> Void)? = nil) {
		let index = min(activateCallCount, activateErrors.count - 1)
		activateCallCount += 1
		lastConfiguration = configuration
		let error = activateErrors[index]
		guard !parkedBehindActivation({ completion?(error) }) else { return }
		completion?(error)
	}

	/// Consumes `getFlowResults[min(callCount, count - 1)]` — walks the queue forward one entry per
	/// call and then repeats the last entry forever, so a check never has to pad the queue out to
	/// however many calls it thinks might happen.
	///
	/// `fetchPolicy` is not modelled: the package never passes one, and a parameter no caller sets
	/// cannot be got wrong. `loadTimeout` is kept because it is the SDK's own answer to AD-05's
	/// deadline question and step 4 may reach for it.
	public static func getFlow(
		placementId: String,
		loadTimeout: TimeInterval? = nil,
		_ completion: @escaping (Result<AdaptyFlow, AdaptyError>) -> Void
	) {
		let index = min(getFlowCallCount, getFlowResults.count - 1)
		getFlowCallCount += 1
		let result = getFlowResults[index]
		guard !parkedBehindActivation({ completion(result) }) else { return }
		guard !holdGetFlow else {
			heldGetFlows.append((placementId: placementId, completion: completion))
			return
		}
		completion(result)
	}

	public static func getPaywallProducts(flow: AdaptyFlow, _ completion: @escaping (Result<[AdaptyPaywallProduct], AdaptyError>) -> Void) {
		getPaywallProductsCallCount += 1
		let result = getPaywallProductsResult
		guard !parkedBehindActivation({ completion(result) }) else { return }
		completion(result)
	}

	public static func logShowFlow(_ flow: AdaptyFlow, _ completion: ((AdaptyError?) -> Void)? = nil) {
		let error = logShowFlowError
		let variationId = flow.variationId
		let record = {
			if error == nil { logShowFlowJournal.append(variationId) }
			completion?(error)
		}
		guard !parkedBehindActivation(record) else { return }
		record()
	}

	public static func getProfile(_ completion: @escaping (Result<AdaptyProfile, AdaptyError>) -> Void) {
		let result = getProfileResult
		guard !parkedBehindActivation({ completion(result) }) else { return }
		guard !holdGetProfile else {
			heldGetProfiles.append(completion)
			return
		}
		completion(result)
	}

	public static func updateProfile(params: AdaptyProfileParameters, _ completion: ((AdaptyError?) -> Void)? = nil) {
		let error = updateProfileError
		let record = {
			if error == nil { updateProfileJournal.append(params) }
			completion?(error)
		}
		guard !parkedBehindActivation(record) else { return }
		guard !holdUpdateProfile else {
			heldUpdateProfiles.append { completion?($0) }
			return
		}
		record()
	}

	/// Serialises FIRST, exactly as upstream (`Adapty+Completion.swift:137-144`): a payload that will
	/// not turn into JSON answers `.wrongParam` synchronously, on the caller's own stack, before any
	/// activation wait and before any network call. AD-06 row 11.
	public static func updateExternalAttribution(
		_ attribution: [AnyHashable: Any],
		provider: AdaptyExternalAttributionProvider,
		_ completion: ((AdaptyError?) -> Void)? = nil
	) {
		guard JSONSerialization.isValidJSONObject(attribution) else {
			completion?(AdaptyError(.wrongParam))
			return
		}
		let error = externalAttributionError
		let record = {
			if error == nil { externalAttributionJournal.append((provider: provider, attribution: attribution)) }
			completion?(error)
		}
		guard !parkedBehindActivation(record) else { return }
		record()
	}

	public static func setIntegrationIdentifier(
		_ identifiers: AdaptyIntegrationIdentifier...,
		completion: ((AdaptyError?) -> Void)? = nil
	) {
		let error = integrationIdentifierError
		let record = {
			if error == nil { integrationIdentifierJournal.append(contentsOf: identifiers) }
			completion?(error)
		}
		guard !parkedBehindActivation(record) else { return }
		record()
	}

	public static func makePurchase(product: AdaptyPaywallProduct, _ completion: @escaping (Result<AdaptyPurchaseResult, AdaptyError>) -> Void) {
		let result = makePurchaseResult
		guard !parkedBehindActivation({ completion(result) }) else { return }
		guard !holdMakePurchase else {
			heldPurchases.append(completion)
			return
		}
		completion(result)
	}

	public static func restorePurchases(_ completion: @escaping (Result<AdaptyProfile, AdaptyError>) -> Void) {
		restorePurchasesCallCount += 1
		let result = restorePurchasesResult
		guard !parkedBehindActivation({ completion(result) }) else { return }
		completion(result)
	}
}
