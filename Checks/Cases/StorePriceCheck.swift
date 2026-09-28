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

		// 4. Thousands separators, including a non-breaking space.
		check(
			StorePrice.corrected(raw: 1, displayPrice: "$1,299.99", formatStyle: style(code: "USD", locale: "en_US")) == 1299.99,
			"row 4a: en_US thousands comma must parse to 1299.99"
		)
		check(
			StorePrice.corrected(raw: 1, displayPrice: "1.299,99 €", formatStyle: style(code: "EUR", locale: "de_DE")) == 1299.99,
			"row 4b: de_DE thousands dot must parse to 1299.99"
		)
		check(
			StorePrice.corrected(raw: 1, displayPrice: "1 299,99 ₽", formatStyle: style(code: "RUB", locale: "ru_RU")) == 1299.99,
			"row 4c: ru_RU thousands with a regular space must parse to 1299.99"
		)
		check(
			StorePrice.corrected(raw: 1, displayPrice: "1\u{00A0}299,99 ₽", formatStyle: style(code: "RUB", locale: "ru_RU")) == 1299.99,
			"row 4d: ru_RU thousands with a non-breaking space must parse to 1299.99"
		)

		// 5. No decimal subunit / whole-number display forms.
		check(
			StorePrice.corrected(raw: 3, displayPrice: "¥3,000", formatStyle: style(code: "JPY", locale: "ja_JP")) == 3000,
			"row 5a: JPY has no minor unit — ¥3,000 must parse to 3000"
		)
		check(
			StorePrice.corrected(raw: 2, displayPrice: "$25", formatStyle: style(code: "USD", locale: "en_US")) == 25,
			"row 5b: a bare \"$25\" must parse to 25"
		)
		check(
			StorePrice.corrected(raw: 2, displayPrice: "$25.00", formatStyle: style(code: "USD", locale: "en_US")) == 25,
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

		if failures.isEmpty {
			print("StorePrice (PM-07 row 17): 16/16 OK")
		} else {
			print("\(failures.count) check(s) failed:")
			for failure in failures {
				print("  - \(failure)")
			}
			exit(1)
		}
	}
}
