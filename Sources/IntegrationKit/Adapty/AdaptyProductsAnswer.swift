//
//  AdaptyProductsAnswer.swift
//  IntegrationKit
//

import Foundation

/// AD-03 row 1: an empty list is not an answer. "The paywall has not arrived yet" and "loading the
/// products failed" both used to come back as `[]`, and the caller had to choose between a spinner
/// and an error message with nothing to choose on.
enum AdaptyProductsAnswer {
	/// Products are here.
	case products([PremiumProduct])
	/// The placement's paywall is not loaded yet — ask again, this is a spinner.
	case notReady
	/// Adapty had the paywall and still could not list its products. Retrying inside this process
	/// is unlikely to help; the store or the dashboard is where the cause is.
	case failed
}
