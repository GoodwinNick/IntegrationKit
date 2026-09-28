//
//  StorePrice.swift
//  IntegrationKit
//

import Foundation

/// PM-07 row 17: `Product.price`/`AdaptyPaywallProduct.price` (the latter just proxies the former —
/// `AdaptyProduct.swift:35-37`) sometimes hand back a `Decimal` StoreKit itself truncated, which does
/// not match what the store actually shows the shopper. `displayPrice`/`localizedPrice` is what the
/// shopper sees and is never wrong, so recover the true number by parsing that string back with the
/// exact `Decimal.FormatStyle.Currency` StoreKit used to produce it (`Product.priceFormatStyle`) —
/// this round-trips correctly regardless of decimal/thousands-separator convention, because it never
/// guesses a locale, it reuses the one StoreKit already picked. Falls back to `raw` whenever there is
/// nothing to parse or the parse itself fails.
enum StorePrice {
	static func corrected(raw: Decimal, displayPrice: String?, formatStyle: Decimal.FormatStyle.Currency?) -> Decimal {
		guard let displayPrice, let formatStyle else { return raw }
		return (try? formatStyle.parseStrategy.parse(displayPrice)) ?? raw
	}
}
