//
//  AdaptyDelegate.swift
//  IntegrationKit — Checks/Stubs
//
//  Stand-in for `AdaptyDelegate` (Adapty 4.1.3, `AdaptyDelegate.swift:10-35`). 2.10.x declared one
//  method; 4.1.3 declares five, four of them with default implementations — so a conformer that
//  implements only `didLoadLatestProfile` still compiles, and inherits whatever the defaults do.
//
//  That is the trap this file exists to reproduce, and `didReceivePromotedPurchase` is the one that
//  bites: its default (`:24-29`) starts `Adapty.makePurchase(product:)` on its own. Every other
//  default is empty.
//
//  All five are declared here even though the package will implement two, because a protocol that
//  omits a method cannot fail a build: Swift accepts the implementation as an ordinary method, calls
//  it never, and no check can tell.
//
//  Divergence: upstream also requires `Sendable`. The stub asks only for `AnyObject` — the harness
//  is single-threaded and `AdaptyService` is an actor, so a `Sendable` requirement here would buy
//  nothing and force `@unchecked` onto the check's own fixtures.
//

import Foundation

public protocol AdaptyDelegate: AnyObject {
	/// Implement this delegate method to receive automatic profile updates.
	func didLoadLatestProfile(_ profile: AdaptyProfile)

	func didReceivePromotedPurchase(_ product: AdaptyPromotedProduct)

	func onInstallationDetailsSuccess(_ details: AdaptyInstallationDetails)

	func onInstallationDetailsFail(error: AdaptyError)

	func onUnfinishedTransaction(_ adaptyUnfinishedTransaction: AdaptyUnfinishedTransaction)
}

public extension AdaptyDelegate {
	/// The dangerous default, reproduced: not implementing this method means agreeing to buy.
	/// The stub records the attempt instead of starting one, so a check can prove the service
	/// overrode it — `Adapty.promotedPurchaseAutoBuyCount`.
	func didReceivePromotedPurchase(_ product: AdaptyPromotedProduct) {
		Adapty.recordPromotedPurchaseAutoBuy(product)
	}

	func onInstallationDetailsSuccess(_: AdaptyInstallationDetails) {}
	func onInstallationDetailsFail(error _: AdaptyError) {}

	func onUnfinishedTransaction(_: AdaptyUnfinishedTransaction) {}
}
