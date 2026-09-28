//
//  StorePriceCheck.swift
//  IntegrationKit
//
//  PM-07 row 17 — pure Decimal/Foundation, no StoreKit or Adapty stub needed: `StorePrice` never
//  names `StoreKit.Product` in its signature, so it is testable directly.
//  Run:  ./Checks/store-price-check.sh
//

import Foundation

@main
enum StorePriceCheck {
	static var failures: [String] = []

	static func check(_ condition: @autoclosure () -> Bool, _ message: @autoclosure () -> String) {
		guard !condition() else { return }
		let text = message()
		failures.append(text)
		print("FAILED: \(text)")
	}

	static func style(code: String, locale: String) -> Decimal.FormatStyle.Currency {
		Decimal.FormatStyle.Currency(code: code, locale: Locale(identifier: locale))
	}

	static func main() {
		// 1. The observed bug (video-to-mp3, kit 0.7.4): StoreKit's own `price` truncated to 24 for
		//    a $24.99 product, en_US/USD storefront; `displayPrice` stayed correct.
		check(
			StorePrice.corrected(raw: 24, displayPrice: "$24.99", formatStyle: style(code: "USD", locale: "en_US")) == 24.99,
			"row 1 (bug): raw 24 + display \"$24.99\" must recover 24.99"
		)

		// 2. Ordinary case: raw already correct, display agrees — must not change.
		check(
			StorePrice.corrected(raw: 24.99, displayPrice: "$24.99", formatStyle: style(code: "USD", locale: "en_US")) == 24.99,
			"row 2: an already-correct raw price must pass through unchanged"
		)

		// 3. Comma-decimal locales.
		check(
			StorePrice.corrected(raw: 24, displayPrice: "24,99 €", formatStyle: style(code: "EUR", locale: "de_DE")) == 24.99,
			"row 3a: de_DE/EUR comma-decimal display must parse to 24.99"
		)
		check(
			StorePrice.corrected(raw: 24, displayPrice: "24,99 ₴", formatStyle: style(code: "UAH", locale: "uk_UA")) == 24.99,
			"row 3b: uk_UA/UAH comma-decimal display must parse to 24.99"
		)

		// 4. Thousands separators, including a non-breaking space. `raw` is the realistic shape of
		//    the bug — StoreKit dropping the fractional cents, not an arbitrary wrong number.
		check(
			StorePrice.corrected(raw: 1299, displayPrice: "$1,299.99", formatStyle: style(code: "USD", locale: "en_US")) == 1299.99,
			"row 4a: en_US thousands comma must parse to 1299.99"
		)
		check(
			StorePrice.corrected(raw: 1299, displayPrice: "1.299,99 €", formatStyle: style(code: "EUR", locale: "de_DE")) == 1299.99,
			"row 4b: de_DE thousands dot must parse to 1299.99"
		)
		check(
			StorePrice.corrected(raw: 1299, displayPrice: "1 299,99 ₽", formatStyle: style(code: "RUB", locale: "ru_RU")) == 1299.99,
			"row 4c: ru_RU thousands with a regular space must parse to 1299.99"
		)
		check(
			StorePrice.corrected(raw: 1299, displayPrice: "1\u{00A0}299,99 ₽", formatStyle: style(code: "RUB", locale: "ru_RU")) == 1299.99,
			"row 4d: ru_RU thousands with a non-breaking space must parse to 1299.99"
		)

		// 5. No decimal subunit / whole-number display forms — `raw` is already correct here (no
		//    fractional cents exist to drop), so the guard (row 8) must leave it untouched.
		check(
			StorePrice.corrected(raw: 3000, displayPrice: "¥3,000", formatStyle: style(code: "JPY", locale: "ja_JP")) == 3000,
			"row 5a: JPY has no minor unit — ¥3,000 must parse to 3000"
		)
		check(
			StorePrice.corrected(raw: 25, displayPrice: "$25", formatStyle: style(code: "USD", locale: "en_US")) == 25,
			"row 5b: a bare \"$25\" must parse to 25"
		)
		check(
			StorePrice.corrected(raw: 25, displayPrice: "$25.00", formatStyle: style(code: "USD", locale: "en_US")) == 25,
			"row 5c: \"$25.00\" must parse to 25"
		)

		// 6. Zero — a free introductory offer.
		check(
			StorePrice.corrected(raw: 0, displayPrice: "$0.00", formatStyle: style(code: "USD", locale: "en_US")) == 0,
			"row 6: a free offer's \"$0.00\" must parse to 0"
		)

		// 7. Fallback: unparseable, empty, or missing display price/format style — trust `raw`.
		check(
			StorePrice.corrected(raw: 24.99, displayPrice: "not a price", formatStyle: style(code: "USD", locale: "en_US")) == 24.99,
			"row 7a: an unparseable display string must fall back to raw"
		)
		check(
			StorePrice.corrected(raw: 24.99, displayPrice: "", formatStyle: style(code: "USD", locale: "en_US")) == 24.99,
			"row 7b: an empty display string must fall back to raw"
		)
		check(
			StorePrice.corrected(raw: 24.99, displayPrice: nil, formatStyle: style(code: "USD", locale: "en_US")) == 24.99,
			"row 7c: a missing display price must fall back to raw"
		)
		check(
			StorePrice.corrected(raw: 24.99, displayPrice: "$24.99", formatStyle: nil) == 24.99,
			"row 7d: a missing format style must fall back to raw"
		)

		// 8. Guard (flagged by masterViking 2026-09-28): the Adapty path's `formatStyle` is
		//    reconstructed from `currencyCode` + `Locale.autoupdatingCurrent`, not the exact one that
		//    produced `displayPrice` — a device whose locale disagrees with the storefront could parse
		//    successfully but land on the WRONG number, silently replacing an already-correct `raw`.
		//    `corrected` must only ever apply a parsed value when `raw` itself carries the truncation
		//    bug's signature: a whole number within 1 unit of the parsed value. An already-fractional
		//    `raw` — proof nothing was truncated — must pass through unchanged no matter what a
		//    mismatched-locale parse produces.
		check(
			StorePrice.corrected(raw: 1299.99, displayPrice: "$1,299.99", formatStyle: style(code: "USD", locale: "uk_UA")) == 1299.99,
			"row 8a: a non-whole, already-correct raw must survive a mismatched-locale display parse"
		)
		check(
			StorePrice.corrected(raw: 24.99, displayPrice: "$24.99", formatStyle: style(code: "USD", locale: "de_DE")) == 24.99,
			"row 8b: de_DE mismatched-locale parsing \"$24.99\" silently yields 2499 — raw must not be replaced"
		)
		check(
			StorePrice.corrected(raw: 24.99, displayPrice: "$24.99", formatStyle: style(code: "USD", locale: "uk_UA")) == 24.99,
			"row 8c: a mismatched locale that fails to parse must still fall back to raw"
		)
		check(
			StorePrice.corrected(raw: 25, displayPrice: "$24.99", formatStyle: style(code: "USD", locale: "en_US")) == 24.99,
			"row 8d: a rounded (not just truncated) raw within 1 unit must still be corrected"
		)
		check(
			StorePrice.corrected(raw: 1299, displayPrice: "$1,299.00", formatStyle: style(code: "USD", locale: "de_DE")) == 1299,
			"row 8e: a whole, already-correct raw must survive even a wildly wrong mismatched-locale parse (1.299)"
		)

		// 9. Locale-agnostic fallback (masterViking/user 2026-09-28): Adapty's own dump showed
		//    `"priceString": "24,99"` next to a correct `"priceFormatted": "$24.99"` — a comma-decimal
		//    reading of a USD price with no clean matching locale at all. No single reconstructed
		//    locale reads every one of these correctly (`en_US`/`de_DE` both misread "24,99 US$" or
		//    "$24.99" into 2499; `uk_UA` throws on "$24.99"), so when the locale-based reading is
		//    rejected or fails outright, fall back to reading the string by structure alone: drop every
		//    non-digit, non-`,`/`.` character (symbols, letters, plain and non-breaking whitespace),
		//    then treat the LAST separator as decimal exactly when it is followed by as many digits as
		//    the currency's own minor unit — locale-independent, `NumberFormatter.maximumFractionDigits`.
		check(
			StorePrice.corrected(raw: 24, displayPrice: "24,99 US$", formatStyle: style(code: "USD", locale: "en_US")) == 24.99,
			"row 9a: en_US misreads \"24,99 US$\" as 2499 — the loose fallback must still recover 24.99"
		)
		check(
			StorePrice.corrected(raw: 24, displayPrice: "$24.99", formatStyle: style(code: "USD", locale: "de_DE")) == 24.99,
			"row 9b: de_DE misreads \"$24.99\" as 2499 — the loose fallback must still recover 24.99"
		)
		check(
			StorePrice.corrected(raw: 24, displayPrice: "24,99 US$", formatStyle: style(code: "USD", locale: "uk_UA")) == 24.99,
			"row 9c: uk_UA reads \"24,99 US$\" correctly on its own — must still land on 24.99"
		)
		check(
			StorePrice.corrected(raw: 24, displayPrice: "24,99\u{00A0}US$", formatStyle: style(code: "USD", locale: "en_US")) == 24.99,
			"row 9d: a non-breaking space before \"US$\" must not block the loose fallback"
		)
		check(
			StorePrice.corrected(raw: 24, displayPrice: "24,99\u{00A0}$", formatStyle: style(code: "USD", locale: "en_US")) == 24.99,
			"row 9e: a non-breaking space before a bare \"$\" must not block the loose fallback"
		)
		check(
			StorePrice.corrected(raw: 1299, displayPrice: "1.299,99 €", formatStyle: style(code: "EUR", locale: "en_US")) == 1299.99,
			"row 9f: an en_US style reading a de-style EUR display must still recover 1299.99 via the loose fallback"
		)

		if failures.isEmpty {
			print("StorePrice (PM-07 row 17): 27/27 OK")
		} else {
			print("\(failures.count) check(s) failed:")
			for failure in failures {
				print("  - \(failure)")
			}
			exit(1)
		}
	}
}
