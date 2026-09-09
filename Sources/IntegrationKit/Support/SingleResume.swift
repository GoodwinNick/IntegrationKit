//
//  SingleResume.swift
//  IntegrationKit
//

import Foundation

/// `withCheckedContinuation` for SDK callbacks that may fire more than once.
///
/// A second `resume` on a continuation is a hard crash, not a warning, and the same shape of bug in
/// any callback→async wrapper would look identical from the outside — so all of them go through
/// here, not just the purchase one. Second and later calls are dropped on purpose; the log line is
/// what makes a real double callback visible instead of silent.
///
/// The double callback this was written for is NOT reproducible on the Adapty 2.10.4 pin: a
/// cancelled `makePurchase` removes its handlers from the dictionary before invoking them. The
/// guard stays because it is nearly free and covers every other call, but nothing here is evidence
/// that Adapty double-calls today (AD-04, "what was checked and is not a risk").
///
/// It guards the second answer and nothing else. An SDK that never calls back at all leaves the
/// caller waiting forever — that is what `withTimeout` is for, and every wrapper in this package
/// uses both.
func withSingleResume<T>(_ body: (@escaping (T) -> Void) -> Void) async -> T {
	await withCheckedContinuation { continuation in
		let lock = NSLock()
		var resumed = false
		body { value in
			lock.lock()
			let isFirst = !resumed
			resumed = true
			lock.unlock()
			guard isFirst else {
				debugLog(level: .error, "SDK callback fired more than once — extra resume dropped")
				return
			}
			continuation.resume(returning: value)
		}
	}
}
