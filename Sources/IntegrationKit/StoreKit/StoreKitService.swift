//
//  StoreKitService.swift
//  IntegrationKit
//
//  The Apple half of the premium state, inside the package now: the app hands over a shared
//  secret and its product ids and stops owning StoreKit code. Mechanics taken from the shipped
//  `VideoToMp3.SubscriptionService` — the SwiftyStoreKit calls are the ones already proven in the
//  store, nothing app-specific came along.
//

import Foundation
import StoreKit
import SwiftyStoreKit

final class StoreKitService: AppleSubscribing {
	private let sharedSecret: String
	private let productIds: Set<String>

	/// An empty `sharedSecret` means the app did not configure receipt validation: `checkReceipt`
	/// then answers `nil` — "not checked" — and everything else keeps working.
	init(sharedSecret: String, productIds: Set<String>) {
		self.sharedSecret = sharedSecret
		self.productIds = productIds
	}

	/// Finishes purchases that were interrupted mid-flight — the app killed during a payment, an
	/// ask-to-buy approved days later. Without it the transaction stays in the queue forever and
	/// the user paid for nothing. Called once from the composition root.
	///
	/// `onDelivered` fires only when something actually arrived: the receipt gains that purchase
	/// only after it is finished, so the premium state has to be re-asked afterwards — `start()`'s
	/// own refresh has already run by then.
	func completeTransactions(onDelivered: @escaping () -> Void) {
		SwiftyStoreKit.completeTransactions(atomically: true) { purchases in
			var delivered = false
			for purchase in purchases {
				switch purchase.transaction.transactionState {
					case .purchased, .restored:
						delivered = true
						if purchase.needsFinishTransaction {
							SwiftyStoreKit.finishTransaction(purchase.transaction)
						}
					case .failed, .purchasing, .deferred:
						break
					@unknown default:
						break
				}
			}
			debugLog("[IntegrationKit] completeTransactions: \(purchases.count) pending, delivered: \(delivered)")
			if delivered {
				onDelivered()
			}
		}
	}

	// MARK: - AppleSubscribing

	/// `nil` means the receipt could not be checked — never "no subscription". An inactive answer
	/// is only returned when the receipt was read and carries no active subscription of ours.
	///
	/// PM-08 row 5: a purchase the queue just delivered is NOT answered from here — the receipt
	/// reports only what the receipt says. That mark lives one layer up, in
	/// `PremiumService.purchaseDelivered()`, the same place `purchase` and `restore` carry it.
	func checkReceipt() async -> ReceiptAnswer? {
		guard !sharedSecret.isEmpty else { return nil }
		// A sandbox receipt against the production validator can only ever answer 21007, so there
		// is nothing to learn from asking. TestFlight and the simulator land here.
		guard Bundle.main.appStoreReceiptURL?.lastPathComponent != "sandboxReceipt" else { return nil }

		let validator = AppleReceiptValidator(service: .production, sharedSecret: sharedSecret)
		let receipt: ReceiptInfo? = await withSingleResume { resume in
			SwiftyStoreKit.verifyReceipt(using: validator) { result in
				switch result {
					case .success(let receipt):
						resume(receipt)
					case .error(let error):
						debugLog("[IntegrationKit] receipt verification failed: \(error)")
						resume(nil)
				}
			}
		}
		guard let receipt else { return nil }

		for productId in productIds {
			switch SwiftyStoreKit.verifySubscription(ofType: .autoRenewable, productId: productId, inReceipt: receipt) {
				case .purchased(let expiryDate, _):
					return ReceiptAnswer(isActive: true, expiresAt: expiryDate)
				case .expired, .notPurchased:
					continue
			}
		}
		return ReceiptAnswer(isActive: false, expiresAt: nil)
	}

	func restore() async -> RestoreOutcome {
		await withSingleResume { resume in
			SwiftyStoreKit.restorePurchases(atomically: true) { results in
				// `atomically: true` finishes them already; the guard is what makes this correct
				// anyway if that ever changes.
				for purchase in results.restoredPurchases where purchase.needsFinishTransaction {
					SwiftyStoreKit.finishTransaction(purchase.transaction)
				}
				// Something restored wins over something failed: the user got their subscription
				// back, and half a restore is still a restore.
				if !results.restoredPurchases.isEmpty {
					resume(.restored)
				} else if !results.restoreFailedPurchases.isEmpty {
					debugLog("[IntegrationKit] restore failed: \(results.restoreFailedPurchases)")
					resume(.failed)
				} else {
					resume(.nothingToRestore)
				}
			}
		}
	}

	func purchase(productId: String) async -> PurchaseOutcome {
		await withSingleResume { resume in
			SwiftyStoreKit.purchaseProduct(productId, atomically: true) { result in
				switch result {
					case .success(let purchase):
						if purchase.needsFinishTransaction {
							SwiftyStoreKit.finishTransaction(purchase.transaction)
						}
						resume(.purchased)
					case .error(let error):
						switch error.code {
							case .paymentCancelled, .overlayCancelled:
								resume(.cancelled)
							default:
								debugLog("[IntegrationKit] purchase failed: \(error)")
								resume(.failed)
						}
					case .deferred:
						// Ask to buy: neither bought nor refused. Not a purchase now — when the
						// parent approves it, `completeTransactions` picks it up at the next launch.
						resume(.failed)
				}
			}
		}
	}

	/// Prices for the ids a paywall lists. A missing key means the store said nothing about that
	/// id — the caller falls back to Adapty's copy rather than dropping the product.
	func products(ids: Set<String>) async -> [String: PremiumProduct] {
		await storeProducts(ids: ids).mapValues(PremiumProduct.init(product:))
	}

	/// The raw StoreKit answer. Kept separate from the mapping above so `SKProduct` never escapes
	/// this file — a different name, not an overload, because two methods that differ only by
	/// return type are exactly the ambiguity nobody wants to debug.
	private func storeProducts(ids: Set<String>) async -> [String: SKProduct] {
		guard !ids.isEmpty else { return [:] }
		return await withSingleResume { resume in
			SwiftyStoreKit.retrieveProductsInfo(ids) { result in
				if let error = result.error {
					debugLog("[IntegrationKit] retrieveProductsInfo failed: \(error)")
				}
				resume(Dictionary(result.retrievedProducts.map { ($0.productIdentifier, $0) }, uniquingKeysWith: { first, _ in first }))
			}
		}
	}
}
