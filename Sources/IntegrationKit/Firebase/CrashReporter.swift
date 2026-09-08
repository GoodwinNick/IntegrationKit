//
//  CrashReporter.swift
//  IntegrationKit
//

import Foundation
import FirebaseCrashlytics

struct CrashReporter: CrashReporting {

	init() {}

	func recordNonFatal(_ tag: String, _ error: Error, _ info: [String: Any]) {
		let nsError = error as NSError
		let isNoise = nsError.domain == NSURLErrorDomain
			&& (nsError.code == NSURLErrorNotConnectedToInternet || nsError.code == NSURLErrorCancelled)
		guard !isNoise else { return }

		Crashlytics.crashlytics().record(error: error, userInfo: info)
	}
}
