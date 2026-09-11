//
//  FakeAppleStore.swift
//  IntegrationKit
//
//  TM-04 and TM-05: Apple's seat in the graph during a test run. No payment queue, no receipt
//  validation, no system dialog — nothing here leaves the process (invariant 5). It answers the same
//  protocol the real StoreKit layer does, so PM-02, PM-04 and PM-05 run unchanged above it.
//

import Foundation

final class FakeAppleStore: AppleSubscribing {

	private static let tag = "TestMode"

	private let flags: TestModeFlags
	private let productIds: Set<String>

	init(flags: TestModeFlags, productIds: Set<String>) {
		self.flags = flags
		self.productIds = productIds
	}

	/// TM-04 row 1: no `-receipt*` flag means the receipt was not checked. `false` here would take
	/// premium away in every test that never mentioned it, which is the one thing the reserve source
	/// is not allowed to do (PM-03).
	///
	/// TM-04 row 2: the answer always carries a date. Against a standing local-purchase mark the date
	/// is the only thing that can ever close access — a receipt answering a bare `true`/`false` makes
	/// that mark permanent.
	func checkReceipt() async -> ReceiptAnswer? {
		// TM-04 row 3: the default half-second is why the barrier can be tested at all. With both
		// sources answering instantly every ordering gives the same result, and a barrier that is not
		// there looks like one that works.
		await Self.wait(flags.receiptDelay)
		switch flags.receipt {
			case .unknown:
				debugLog(tag: Self.tag, "receipt not checked — the verdict is built without it")
				return nil
			case .valid:
				return ReceiptAnswer(isActive: true, expiresAt: Date().addingTimeInterval(30 * 24 * 3600))
			case .expired:
				return ReceiptAnswer(isActive: false, expiresAt: Date().addingTimeInterval(-24 * 3600))
		}
	}

	/// "Already premium" is not a case here on purpose. A subscription bought under another Apple ID
	/// or granted in the dashboard leaves the payment queue empty, so the store really does have
	/// nothing to restore — the app's rule that this still counts as success is the app's, and the
	/// state is assembled by passing no restore flag together with `-premium` (TM-05 row 5).
	func restore() async -> RestoreOutcome {
		switch flags.restore {
			case .fails: return .failed
			case .succeeds: return .restored
			case .nothingToRestore: return .nothingToRestore
		}
	}

	/// The StoreKit fallback. Reached only when Adapty asks for a retry, which the fake Adapty source
	/// never does — kept faithful anyway, because the day it is reachable is the day it matters.
	func purchase(productId: String) async -> PurchaseOutcome {
		switch flags.purchase {
			case .succeeds: return .purchased
			case .cancelled: return .cancelled
			case .pending: return .pending
			case .unavailable: return .unavailable
			case .fails: return .failed
		}
	}

	func products(ids: Set<String>) async -> [String: PremiumProduct] {
		if flags.productInfoHangs {
			// TM-05 row 6: a hang, not a failure, and only this call. The premium verdict, purchases
			// and restore all keep working in the same run — a test for an endless paywall spinner
			// must not take every other assertion of that run down with it.
			debugLog(tag: Self.tag, level: .error, "product info hangs by request — this call never answers")
			try? await Task.sleep(nanoseconds: UInt64(365 * 24 * 3600) * 1_000_000_000)
			return [:]
		}
		let priced = ids.map { ($0, TestModeCatalog.product(id: $0, hasTrial: flags.hasTrial)) }
		return Dictionary(uniqueKeysWithValues: priced)
	}

	private static func wait(_ seconds: TimeInterval) async {
		guard seconds > 0 else { return }
		try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
	}
}
