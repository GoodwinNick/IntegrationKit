//
//  WithTimeout.swift
//  IntegrationKit
//

import Foundation

/// Runs `work` with a deadline. `nil` means the deadline won.
///
/// This is not "do not wait for slow networks" — it is the guard against an SDK that never calls
/// its completion at all, which would otherwise leave the caller waiting forever. The losing side
/// is not cancellable (an SDK callback ignores `Task` cancellation), so its answer is simply
/// dropped when it finally arrives — `withSingleResume` is what makes that safe.
func withTimeout<T>(_ seconds: TimeInterval, _ work: @escaping () async -> T) async -> T? {
	await withSingleResume { resume in
		let deadline = Task {
			do {
				try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
				resume(nil)
			} catch {
				// Cancelled because `work` answered first — nothing to report.
			}
		}
		Task {
			let value = await work()
			deadline.cancel()
			resume(value)
		}
	}
}
