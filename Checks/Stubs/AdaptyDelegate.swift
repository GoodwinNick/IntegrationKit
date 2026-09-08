//
//  AdaptyDelegate.swift
//  IntegrationKit — Checks/Stubs
//
//  Stand-in for `AdaptyDelegate` (Adapty 2.10.x). `AdaptyService` conforms to this one method.
//

import Foundation

public protocol AdaptyDelegate: AnyObject {
	func didLoadLatestProfile(_ profile: AdaptyProfile)
}
