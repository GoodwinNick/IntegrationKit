//
//  StoreKitService.swift
//  IntegrationKit
//
//  The Apple half of the premium state, on native StoreKit 2 since 0.7.0. No shared secret, no
//  receipt validator, no completion-block races to hop threads around — every entry point here is
//  already `async` on Apple's own side.
//
//  PM-08: the kit never calls `Transaction.finish()` — not here, not anywhere in `Sources/`. Adapty
//  (full mode) is the only finisher: its own `Transaction.updates` listener finishes what it sees
//  live, and its sweep finishes what a profile sync, restore or activation turns up. A second
//  finisher racing the first is exactly the crash this package is built to avoid.
//

import Foundation
import StoreKit

final class StoreKitService: AppleSubscribing {
	private let productIds: Set<String>

	init(productIds: Set<String>) {
		self.productIds = productIds
	}

	// MARK: - AppleSubscribing

	/// `Transaction.currentEntitlements` reads the device's own transaction cache — it does not
	/// throw and works offline, so unlike a network receipt validator this answers `nil` only for a
	/// genuine surprise (Apple removing the sequence's guarantees), never for "offline" or
	/// "sandbox".
	///
	/// PM-08 row 5: a purchase the queue just delivered is NOT answered from here — this reads only
	/// what StoreKit currently entitles. That mark lives one layer up, in
	/// `PremiumService.purchaseDelivered()`, the same place `purchase` and `restore` carry it.
	func checkReceipt() async -> ReceiptAnswer? {
		var isActive = false
		var latestExpiry: Date?
		for await result in Transaction.currentEntitlements {
			guard case .verified(let transaction) = result, productIds.contains(transaction.productID) else { continue }
			guard let expirationDate = transaction.expirationDate else {
				// A non-expiring entitlement of ours (non-consumable) — active with no expiry to track.
				isActive = true
				continue
			}
			latestExpiry = max(latestExpiry ?? .distantPast, expirationDate)
			if expirationDate > Date() {
				isActive = true
			}
		}
		return ReceiptAnswer(isActive: isActive, expiresAt: latestExpiry)
	}

	/// `AppStore.sync()` refreshes the device's transaction set from the App Store — the StoreKit 2
	/// replacement for `SKReceiptRefreshRequest`, and (per PM-08) not something the kit's own
	/// `finish()` follows: whatever this turns up, Adapty's sweep is what closes it.
	func restore() async -> RestoreOutcome {
		do {
			try await AppStore.sync()
		} catch {
			debugLog("[IntegrationKit] AppStore.sync failed: \(error)")
			return .failed
		}
		for await result in Transaction.currentEntitlements {
			if case .verified(let transaction) = result, productIds.contains(transaction.productID) {
				return .restored
			}
		}
		return .nothingToRestore
	}

	/// The fallback purchase, used when Adapty's own request failed. Deliberately does not call
	/// `finish()` on success (PM-08) — Adapty's listener sees this transaction only if it survives
	/// unfinished to the next launch; the more common path is `PremiumService`'s own `syncReceipt()`
	/// call right after, which drives Adapty's sweep instead.
	func purchase(productId: String) async -> PurchaseOutcome {
		guard AppStore.canMakePayments else { return .unavailable }
		guard let product = await storeProducts(ids: [productId])[productId] else {
			debugLog("[IntegrationKit] purchase: '\(productId)' not found in the store")
			return .unavailable
		}
		do {
			switch try await product.purchase() {
				case .success(.verified):
					return .purchased
				case .success(.unverified(_, let error)):
					// StoreKit's own signature check failed on a transaction we just paid for — the
					// same stance Adapty takes for a transaction its listener cannot verify: not
					// granted. `AppStore.sync()` (restore) is the user's way to retry the check.
					debugLog("[IntegrationKit] purchase: unverified transaction for '\(productId)': \(error)")
					return .failed
				case .userCancelled:
					return .cancelled
				case .pending:
					// Ask to Buy, or a payment still being confirmed: neither bought nor refused.
					return .pending
				@unknown default:
					return .failed
			}
		} catch {
			debugLog("[IntegrationKit] purchase failed: \(error)")
			return .failed
		}
	}

	/// Prices for the ids a paywall lists. A missing key means the store said nothing about that
	/// id — the caller falls back to Adapty's copy rather than dropping the product.
	func products(ids: Set<String>) async -> [String: PremiumProduct] {
		await storeProducts(ids: ids).mapValues(PremiumProduct.init(product:))
	}

	/// The raw StoreKit answer. Kept separate from the mapping above so `StoreKit.Product` never
	/// escapes this file — a different name, not an overload, because two methods that differ only
	/// by return type are exactly the ambiguity nobody wants to debug.
	private func storeProducts(ids: Set<String>) async -> [String: Product] {
		guard !ids.isEmpty else { return [:] }
		do {
			let products = try await Product.products(for: ids)
			let byId = Dictionary(products.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
			if byId.count < ids.count {
				let missing = ids.subtracting(byId.keys)
				debugLog("[IntegrationKit] Product.products(for:) dropped unknown ids: \(missing.sorted())")
			}
			for product in products {
				debugLog("[IntegrationKit] \(Self.describe(product))")
			}
			return byId
		} catch {
			debugLog("[IntegrationKit] Product.products(for:) failed: \(error)")
			return [:]
		}
	}

	/// One line per raw StoreKit answer — the store's own price, region and offer, before anything
	/// in the package merges or caches it. `regionCode`/`currencyCode` come from the pricing locale,
	/// the same one Adapty's own SDK reads its `regionCode` off (`AdaptyProduct.swift`), not from
	/// `Locale.current` — a device roaming on another storefront prices from where the App Store
	/// account is, not from the device's own region setting. `Locale.regionCode` rather than the
	/// newer `Locale.region` — the package's floor is iOS 15.6, and `region` needs iOS 16.
	private static func describe(_ product: Product) -> String {
		let region = product.priceFormatStyle.locale.regionCode ?? "?"
		let currency = product.priceFormatStyle.currencyCode
		let period = product.subscription.map { "\($0.subscriptionPeriod.value) \($0.subscriptionPeriod.unit)" } ?? "none"
		let offer: String
		if let subscription = product.subscription, let intro = subscription.introductoryOffer {
			offer = "\(intro.paymentMode) \(intro.periodCount)×\(intro.period.value) \(intro.period.unit) at \(intro.displayPrice)"
		} else {
			offer = "none"
		}
		return "\(product.id): \(product.displayPrice) (\(product.price) \(currency)), region \(region), type \(product.type.rawValue), period \(period), introOffer \(offer)"
	}
}
