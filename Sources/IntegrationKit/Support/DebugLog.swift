//
//  DebugLog.swift
//  IntegrationKit
//

import Foundation

/// An extra destination for every log line. `nil` in every real build — the checks install one
/// because several schema rows require a *trace* ("the impression was skipped", "the product load
/// failed with code 1000", "the purchase verdict was X"), and a trace can only be asserted on if
/// something can read it back. Nothing outside the checks sets this.
var debugLogSink: ((String) -> Void)?

/// Console logging that exists only in DEBUG — a library has no business printing into the console
/// of the app that embeds it.
///
/// `tag` names the service (`AdaptyService`, `AmplitudeAnalytics`, …) so a line can be traced to
/// one layer without reading the message; `[IntegrationKit]` alone is the fallback for the few
/// lines that belong to no single service.
func debugLog(tag: String? = nil, level: LogLevel = .info, _ message: @autoclosure () -> String) {
	#if DEBUG
		emitLog(tag: tag, level: level, message())
	#else
		// The message is not even built unless someone is listening.
		if debugLogSink != nil {
			emitLog(tag: tag, level: level, message())
		}
	#endif
}

private func emitLog(tag: String?, level: LogLevel, _ message: String) {
	let prefix = tag.map { "[IntegrationKit][\($0)]" } ?? "[IntegrationKit]"
	let suffix = level == .error ? "[error] " : " "
	let line = "\(prefix)\(suffix)\(message)"
	debugLogSink?(line)
	#if DEBUG
		print(line)
	#endif
}
