//
//  AdaptyDeadlines.swift
//  IntegrationKit
//

import Foundation

/// How long `AdaptyService` waits before deciding without the SDK, and how long its caches stay
/// fresh. Every value here exists because a row of the AD-01…AD-07 schemas found a call that can
/// simply never come back: Adapty's completions are allowed not to arrive, and "no answer" must not
/// mean "wait forever".
///
/// One type instead of five initializer parameters, and injectable so a check can drive a
/// three-minute deadline in a third of a second.
struct AdaptyDeadlines {
	/// One SDK call that answers through a completion. A profile the SDK cannot create is retried
	/// once a second for the life of the process and the caller is never woken (AD-05 row 1).
	var call: TimeInterval = 10
	/// A purchase: the App Store sheet, Face ID and a password prompt all happen inside this one
	/// call, so it gets far longer. When it does expire the verdict is `.pending`, not a failure —
	/// the user may still be paying, and Ask to Buy can take days (AD-04 row 1).
	var purchase: TimeInterval = 180
	/// A profile write. Same failure as `call`, third code path (AD-06 row 2).
	var write: TimeInterval = 10
	/// How long after activation a profile may fail to arrive before the layer says so. An invalid
	/// key surfaces as an error nowhere — this is the only symptom there is (AD-01 row 5).
	var firstProfile: TimeInterval = 30
	/// How long a loaded paywall stays fresh. A paywall edited in the dashboard mid-session used to
	/// be cached until the process died (AD-02 row 4).
	var paywallTTL: TimeInterval = 30 * 60

	static let `default` = AdaptyDeadlines()
}
