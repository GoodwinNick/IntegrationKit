//
//  SingleResume.swift
//  IntegrationKit
//

import Foundation

/// `withCheckedContinuation` for SDK callbacks that may fire more than once.
///
/// A second `resume` on a continuation is a hard crash, not a warning. Adapty is known to call
/// back twice on a cancelled `makePurchase` (rewrite spec, open question 3), and the same shape
/// of bug in `getProfile`/`getPaywallProducts` would look identical from the outside — so every
/// callback→async wrapper in the package goes through here, not just the purchase one. The
/// second and later calls are dropped on purpose; the log line is what makes a real double
/// callback visible instead of silent.
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
				debugLog("[IntegrationKit] SDK callback fired more than once — extra resume dropped")
				return
			}
			continuation.resume(returning: value)
		}
	}
}
