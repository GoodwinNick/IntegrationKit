//
//  Configuration.swift
//  IntegrationKit — Checks/Stubs/AmplitudeSwift
//
//  Stand-in for `Configuration` (Amplitude-Swift 1.18.x). Only the initializer
//  `AmplitudeAnalytics.configure` actually calls.
//

import Foundation

public struct Configuration {
	public let apiKey: String

	public init(apiKey: String) {
		self.apiKey = apiKey
	}
}
