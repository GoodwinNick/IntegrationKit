//
//  LogLevel.swift
//  IntegrationKit
//

import Foundation

/// Two levels, because that is all the schemas ask for: `info` is "this happened", `error` is
/// "this did not happen and someone has to know".
enum LogLevel: String {
	case info
	case error
}
