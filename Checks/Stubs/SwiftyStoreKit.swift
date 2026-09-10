//
//  SwiftyStoreKit.swift
//  IntegrationKit — Checks/Stubs
//
//  Stand-in for SwiftyStoreKit. Compiled into a module called `SwiftyStoreKit`, so `StoreKitService`
//  and the `Premium*+StoreKit` mappings build and run outside Xcode with their `import SwiftyStoreKit`
//  untouched. Only the members that source actually names are here; `SKPaymentTransactionState`,
//  `SKProduct` and friends come straight from the real `import StoreKit` instead of being stubbed —
//  they are plain Apple types `StoreKitService` never asks this module for.
//
//  Every method reads its answer from a static var and counts its own calls — a test sets the var,
//  runs `StoreKitService`, then reads the counter. Same idea as `FakeAdapty`/`FakeApple`, just static
//  because the real SDK is a namespace of static calls, never an injected instance.
//

import Foundation
import StoreKit

public protocol PaymentTransaction {
	var transactionState: SKPaymentTransactionState { get }
}

/// The one concrete `PaymentTransaction` this stub hands out. Real `SKPaymentTransaction` has no
/// public initializer — a test could never build one — so this stands in for it. `label` exists
/// only so a test can tell two finished transactions apart; `StoreKitService` never reads it.
public final class StubTransaction: PaymentTransaction {
	public let transactionState: SKPaymentTransactionState
	public let label: String

	public init(state: SKPaymentTransactionState, label: String = "") {
		transactionState = state
		self.label = label
	}
}

public struct Purchase {
	public let transaction: PaymentTransaction
	public let productId: String
	public let needsFinishTransaction: Bool

	public init(transaction: PaymentTransaction, productId: String, needsFinishTransaction: Bool) {
		self.transaction = transaction
		self.productId = productId
		self.needsFinishTransaction = needsFinishTransaction
	}
}

public struct RestoreResults {
	public let restoredPurchases: [Purchase]
	public let restoreFailedPurchases: [String]

	public init(restoredPurchases: [Purchase] = [], restoreFailedPurchases: [String] = []) {
		self.restoredPurchases = restoredPurchases
		self.restoreFailedPurchases = restoreFailedPurchases
	}
}

public struct SKPurchaseError: Error {
	public enum Code {
		case paymentCancelled
		case overlayCancelled
		case unknown
	}

	public let code: Code

	public init(code: Code) {
		self.code = code
	}
}

public enum PurchaseResult {
	case success(Purchase)
	case error(SKPurchaseError)
	case deferred
}

public typealias ReceiptInfo = [String: Any]

public struct StubReceiptError: Error {}

public enum VerifyReceiptResult {
	case success(ReceiptInfo)
	case error(Error)
}

public enum SubscriptionType {
	case autoRenewable
}

// ponytail: no stored properties, nothing here constructs one yet — add fields when a check needs
// receipt item data.
public struct ReceiptItem {}

public enum VerifySubscriptionResult {
	case purchased(expiryDate: Date, items: [ReceiptItem])
	case expired
	case notPurchased
}

public struct RetrieveResults {
	public let retrievedProducts: Set<SKProduct>
	public let invalidProductIDs: Set<String>
	public let error: Error?

	public init(retrievedProducts: Set<SKProduct> = [], invalidProductIDs: Set<String> = [], error: Error? = nil) {
		self.retrievedProducts = retrievedProducts
		self.invalidProductIDs = invalidProductIDs
		self.error = error
	}
}

public struct AppleReceiptValidator {
	public enum VerifyReceiptURLType {
		case production
	}

	public let service: VerifyReceiptURLType
	public let sharedSecret: String

	public init(service: VerifyReceiptURLType, sharedSecret: String) {
		self.service = service
		self.sharedSecret = sharedSecret
	}
}

// The real SwiftyStoreKit formats these for display; `StoreKitService`'s neighbors
// (`PremiumProduct+StoreKit`, `PremiumOffer+StoreKit`) import SwiftyStoreKit for exactly this.
// No check here exercises pricing, so the value itself does not matter.
extension SKProduct {
	public var localizedPrice: String? { nil }
}

extension SKProductDiscount {
	public var localizedPrice: String? { nil }
}

/// The stubbed SDK namespace. Every member is static because `StoreKitService` calls
/// `SwiftyStoreKit.foo(...)` directly, never through an injected instance — so control has to go
/// through statics too. `reset()` clears every answer and counter; call it at the top of each check
/// row so one row's setup cannot leak into the next.
public enum SwiftyStoreKit {
	public static var completeTransactionsResult: [Purchase] = []
	public static var restorePurchasesResult = RestoreResults()
	public static var purchaseProductResult: PurchaseResult = .error(SKPurchaseError(code: .unknown))
	public static var verifyReceiptResult: VerifyReceiptResult = .error(StubReceiptError())
	public static var verifySubscriptionResult: VerifySubscriptionResult = .notPurchased
	public static var retrieveProductsInfoResult = RetrieveResults()

	public static private(set) var finishTransactionCalls: [PaymentTransaction] = []
	public static private(set) var verifyReceiptCallCount = 0

	/// PM-07 row 13: which thread each entry point was entered on. The real SDK keeps unsynchronised
	/// dictionaries behind every one of these calls and hands its own callbacks back on the main
	/// thread, so "which thread did our side arrive on" is the whole of what a stub can observe —
	/// the corruption itself surfaces later, somewhere else, as a garbage pointer.
	public static private(set) var callThreads: [(name: String, isMain: Bool)] = []

	private static func recordThread(_ name: String) {
		callThreads.append((name, Thread.isMainThread))
	}

	public static func reset() {
		completeTransactionsResult = []
		restorePurchasesResult = RestoreResults()
		purchaseProductResult = .error(SKPurchaseError(code: .unknown))
		verifyReceiptResult = .error(StubReceiptError())
		verifySubscriptionResult = .notPurchased
		retrieveProductsInfoResult = RetrieveResults()
		finishTransactionCalls = []
		verifyReceiptCallCount = 0
		callThreads = []
	}

	public static func completeTransactions(atomically: Bool, completion: @escaping ([Purchase]) -> Void) {
		recordThread("completeTransactions")
		completion(completeTransactionsResult)
	}

	public static func finishTransaction(_ transaction: PaymentTransaction) {
		finishTransactionCalls.append(transaction)
	}

	public static func restorePurchases(atomically: Bool, completion: @escaping (RestoreResults) -> Void) {
		recordThread("restorePurchases")
		completion(restorePurchasesResult)
	}

	public static func purchaseProduct(_ productId: String, atomically: Bool, completion: @escaping (PurchaseResult) -> Void) {
		recordThread("purchaseProduct")
		completion(purchaseProductResult)
	}

	public static func verifyReceipt(using validator: AppleReceiptValidator, completion: @escaping (VerifyReceiptResult) -> Void) {
		recordThread("verifyReceipt")
		verifyReceiptCallCount += 1
		completion(verifyReceiptResult)
	}

	public static func verifySubscription(ofType type: SubscriptionType, productId: String, inReceipt receipt: ReceiptInfo) -> VerifySubscriptionResult {
		verifySubscriptionResult
	}

	public static func retrieveProductsInfo(_ productIds: Set<String>, completion: @escaping (RetrieveResults) -> Void) {
		recordThread("retrieveProductsInfo")
		completion(retrieveProductsInfoResult)
	}
}
