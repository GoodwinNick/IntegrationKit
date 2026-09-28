//
//  StorePrice.swift
//  IntegrationKit
//

import Foundation

/// PM-07 row 17 — not yet implemented. Placeholder that keeps today's behaviour (trust `raw`
/// unconditionally), so `store-price-check.sh` runs red until the fix lands.
enum StorePrice {
	static func corrected(raw: Decimal, displayPrice: String?, formatStyle: Decimal.FormatStyle.Currency?) -> Decimal {
		raw
	}
}
