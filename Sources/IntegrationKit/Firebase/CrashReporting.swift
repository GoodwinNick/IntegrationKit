//
//  CrashReporting.swift
//  IntegrationKit
//

import Foundation

public protocol CrashReporting {
	func recordNonFatal(_ tag: String, _ error: Error, _ info: [String: Any])
}

public extension CrashReporting {
	func recordNonFatal(_ tag: String, _ error: Error) {
		recordNonFatal(tag, error, [:])
	}
}
