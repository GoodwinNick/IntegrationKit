//
//  PriceCache.swift
//  IntegrationKit
//
//  PM-07: what StoreKit answered last time, for when it's silent again — and, for the
//  introductory offer specifically, a safety net against a single `nil` (offer removed in App
//  Store Connect, or StoreKit answering inconsistently just this once), not a safety net against
//  a particular user's own ineligibility for it.
//

import Foundation

/// Cross-session price cache, keyed by product id — the same JSON-in-`Data`-in-`UserDefaults`
/// shape as `UserDefaultsPremiumStore`. An `actor` because `merge` reads then writes the same
/// dictionary, and two placements resolving at once must not race each other's cache entry.
actor PriceCache {
	private static let tag = "PriceCache"

	private let defaults: UserDefaults
	private let key: String
	private var products: [String: PremiumProduct]

	init(defaults: UserDefaults = .standard, key: String = "priceCacheKey") {
		self.defaults = defaults
		self.key = key
		self.products = defaults.data(forKey: key)
			.flatMap { try? JSONDecoder().decode([String: PremiumProduct].self, from: $0) } ?? [:]
	}

	/// PM-07's merge rule: price, currency and subscription period are always fresh; the
	/// introductory offer keeps its cached value when StoreKit answers `nil` this time. Writes
	/// the merge back to disk and returns it, keyed the same as `fresh`.
	func merge(fresh: [String: PremiumProduct]) -> [String: PremiumProduct] {
		var carriedCount = 0
		for (id, product) in fresh {
			guard product.introductoryOffer == nil, let carried = products[id]?.introductoryOffer else {
				products[id] = product
				continue
			}
			carriedCount += 1
			products[id] = PremiumProduct(
				id: product.id,
				localizedTitle: product.localizedTitle,
				localizedPrice: product.localizedPrice,
				price: product.price,
				currencyCode: product.currencyCode,
				subscriptionPeriod: product.subscriptionPeriod,
				introductoryOffer: carried
			)
		}
		let data = try? JSONEncoder().encode(products)
		defaults.set(data, forKey: key)
		debugLog(tag: Self.tag, "merge: \(fresh.count) fresh price(s), \(carriedCount) carried an old introductory offer")
		return fresh.keys.reduce(into: [:]) { $0[$1] = products[$1] }
	}

	/// The previous session's answer, for ids StoreKit stayed silent about this time.
	func cached(ids: Set<String>) -> [String: PremiumProduct] {
		let hit = products.filter { ids.contains($0.key) }
		if !ids.isEmpty {
			debugLog(tag: Self.tag, "cached: \(hit.count) of \(ids.count) id(s) served from a previous session — missing \(Array(ids.subtracting(hit.keys)).sorted())")
		}
		return hit
	}
}
