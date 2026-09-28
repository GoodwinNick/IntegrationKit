//
//  StorePrice.swift
//  IntegrationKit
//

import Foundation

/// PM-07 row 17: `Product.price`/`AdaptyPaywallProduct.price` (the latter just proxies the former —
/// `AdaptyProduct.swift:35-37`) sometimes hand back a `Decimal` StoreKit itself truncated, which does
/// not match what the store actually shows the shopper. `displayPrice`/`localizedPrice` is what the
/// shopper sees and is never wrong, so recover the true number from that string instead.
///
/// Two ways to read it, tried in order:
/// 1. `formatStyle.parseStrategy` — exact when `formatStyle` is the one StoreKit itself used
///    (the direct StoreKit path: `product.priceFormatStyle`). The Adapty path can only reconstruct a
///    format style from `currencyCode` + the device's current locale, which will not always match the
///    storefront's — a mismatch can parse "successfully" into the WRONG number (`$24.99` read as
///    `2499` under a comma-decimal locale), so this alone cannot be trusted.
/// 2. A locale-agnostic reading: currency symbols/letters and whitespace (plain or non-breaking) carry
///    no information and are dropped; the LAST remaining `,`/`.` is the decimal separator exactly when
///    it is followed by precisely as many digits as the currency's own minor unit (2 for USD/EUR, 0 for
///    JPY, independent of locale — `NumberFormatter.maximumFractionDigits`); every other separator is
///    grouping. This is what recovers `"24,99 US$"` and similar Adapty-side dumps.
///
/// Neither reading is trusted blindly: a result is only ever taken when `raw` carries the truncation
/// bug's own signature — a whole number within 1 unit of the parsed value. An already-fractional `raw`
/// is proof nothing was truncated, so no parse, however it was produced, may replace it.
enum StorePrice {
	static func corrected(raw: Decimal, displayPrice: String?, formatStyle: Decimal.FormatStyle.Currency?) -> Decimal {
		guard let displayPrice, let formatStyle else { return raw }
		if let parsed = try? formatStyle.parseStrategy.parse(displayPrice), plausible(parsed, against: raw) {
			return parsed
		}
		if let parsed = looseParse(displayPrice, fractionDigits: fractionDigits(for: formatStyle.currencyCode)), plausible(parsed, against: raw) {
			return parsed
		}
		return raw
	}

	private static func plausible(_ parsed: Decimal, against raw: Decimal) -> Bool {
		isWhole(raw) && abs(parsed - raw) < 1
	}

	private static func isWhole(_ value: Decimal) -> Bool {
		var value = value
		var rounded = Decimal()
		NSDecimalRound(&rounded, &value, 0, .down)
		return value == rounded
	}

	private static func looseParse(_ text: String, fractionDigits: Int) -> Decimal? {
		let posix = Locale(identifier: "en_US_POSIX")
		let cleaned = text.filter { $0.isNumber || $0 == "," || $0 == "." }
		guard fractionDigits > 0, let lastSeparator = cleaned.lastIndex(where: { $0 == "," || $0 == "." }) else {
			let digitsOnly = cleaned.filter(\.isNumber)
			return digitsOnly.isEmpty ? nil : Decimal(string: digitsOnly, locale: posix)
		}
		let fraction = cleaned[cleaned.index(after: lastSeparator)...]
		guard fraction.count == fractionDigits, fraction.allSatisfy(\.isNumber) else {
			let digitsOnly = cleaned.filter(\.isNumber)
			return digitsOnly.isEmpty ? nil : Decimal(string: digitsOnly, locale: posix)
		}
		let integer = cleaned[..<lastSeparator].filter(\.isNumber)
		guard !integer.isEmpty else { return nil }
		return Decimal(string: "\(integer).\(fraction)", locale: posix)
	}

	/// Purely a property of the currency (ISO 4217 minor unit), never of the locale — confirmed against
	/// `NumberFormatter` across en_US/de_DE/uk_UA/ja_JP for USD and JPY (identical result every time).
	private static func fractionDigits(for currencyCode: String) -> Int {
		let formatter = NumberFormatter()
		formatter.numberStyle = .currency
		formatter.currencyCode = currencyCode
		formatter.locale = Locale(identifier: "en_US_POSIX")
		return formatter.maximumFractionDigits
	}
}
