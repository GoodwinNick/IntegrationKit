//
//  DebugLog.swift
//  IntegrationKit
//

import Foundation

/// Console logging that exists only in DEBUG — a library has no business
/// printing into the console of the app that embeds it.
func debugLog(_ message: @autoclosure () -> String) {
	#if DEBUG
	print(message())
	#endif
}
