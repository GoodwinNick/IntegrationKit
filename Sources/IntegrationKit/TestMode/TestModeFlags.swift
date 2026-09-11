//
//  TestModeFlags.swift
//  IntegrationKit
//
//  TM-02: everything a UI test asked of the package, read once from the launch arguments and never
//  again (TestMode invariant 3). Plain values only — nothing here knows what a source, a file or a
//  timer is. The graph is built from this in TM-01.
//

import Foundation

struct TestModeFlags {

	/// What Adapty answers. Three states, three names, and none of them is the absence of a flag
	/// (TM-02 row 7): a denial closes access, silence hands the word to the Apple receipt, and the
	/// two are what PM-03 tells apart. The default is a denial, not silence — a defined answer is a
	/// less surprising start, and the AISONG suite is already written against it.
	enum AdaptyAnswer {
		case grant
		case denial
		case silent
	}

	/// What the Apple receipt says. The default is `unknown`, deliberately unlike Adapty's: `false`
	/// here would take premium away in every test that never mentioned the receipt (TM-04 row 1).
	enum Receipt {
		case valid
		case expired
		case unknown
	}

	/// TM-05: priority when several are passed — cancelled → pending → unavailable → failed →
	/// succeeds. Written once, here, rather than as branches scattered over the fake store.
	enum PurchaseResult {
		case succeeds
		case cancelled
		case pending
		case unavailable
		case fails
	}

	/// TM-05: priority — fails → succeeds → nothing. "Already premium" is not a rung of this ladder:
	/// it is the app's own rule, assembled by passing no restore flag together with `-premium`.
	enum RestoreResult {
		case succeeds
		case fails
		case nothingToRestore
	}

	var adapty: AdaptyAnswer = .denial
	/// `nil` means the package's own default level — whatever the app passed as `levels`. A test that
	/// checks a specific access level names it with `-adaptyLevelId` (TM-03 row 5).
	var adaptyLevelId: String?
	var premiumAfter: TimeInterval?
	var noPremiumAfter: TimeInterval?
	/// The app started with its old premium flag already on. Kept apart from ``adapty`` on purpose:
	/// the case an explicit Adapty denial overrides a legacy flag only exists while the two are
	/// different fields (TM-02 row 8).
	var legacyPremium = false
	var noPremiumCache = false

	var receipt: Receipt = .unknown
	var receiptDelay: TimeInterval = 0.5
	var pendingTransaction = false

	var purchase: PurchaseResult = .succeeds
	var purchaseDelay: TimeInterval = 1.5
	var restore: RestoreResult = .nothingToRestore
	var productInfoHangs = false
	var hasTrial = false

	/// Two independent key spaces, as in production: the paywall's own remote config and Firebase
	/// Remote Config are different subsystems with different readers (TM-06 row 1). One key passed to
	/// both flags is two unrelated values, and that is the intended behaviour.
	var paywallValues: [String: Any] = [:]
	var remoteConfigValues: [String: Any] = [:]

	/// What the parse could not make sense of, one line per cause. Carried out rather than recorded:
	/// TM-02 is a pure function, and a parse that writes into a shared list cannot be run twice in one
	/// process by a check. TM-01 is what records these.
	var issues: [String] = []
}
