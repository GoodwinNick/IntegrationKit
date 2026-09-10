//
//  AdaptyUnfinishedTransaction.swift
//  IntegrationKit — Checks/Stubs
//
//  Stand-in for `AdaptyUnfinishedTransaction` (Adapty 4.1.3,
//  `StoreKit/Entities/AdaptyUnfinishedTransaction.swift:11-27`) — what the delegate is handed for
//  every verified transaction the SDK sees, BEFORE it has validated it (`StoreKitPurchaser.swift:65`).
//
//  PM-08 rows 8 and 11 are about this object. Its `finish()` is the only manual way out of
//  `transactionFinishBehavior: .manual`, and it refuses to do anything in observer mode
//  (`:18`) — which is also the mode in which the SDK never observes the queue in the first place.
//
//  Divergence, unavoidable: upstream the whole struct wraps
//  `VerificationResult<StoreKit.Transaction>` and every accessor unwraps it. The stub stores the two
//  values a check could ever assert on — which product, and how many times `finish()` was called.
//  `finish()` here is a counter, not a queue operation: nothing in a harness owns a payment queue.
//

import Foundation

public struct AdaptyUnfinishedTransaction {
	public static private(set) var finishCallCount = 0
	public static private(set) var finishedProductIds: [String] = []

	public static func resetFinishJournal() {
		finishCallCount = 0
		finishedProductIds = []
	}

	public let productId: String
	public let transactionId: UInt64

	public init(productId: String, transactionId: UInt64 = 1) {
		self.productId = productId
		self.transactionId = transactionId
	}

	public func finish() async throws {
		Self.finishCallCount += 1
		Self.finishedProductIds.append(productId)
	}
}
