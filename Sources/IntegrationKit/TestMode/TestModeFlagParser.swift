//
//  TestModeFlagParser.swift
//  IntegrationKit
//
//  TM-02: launch arguments in, a set of source states out. A pure function over `[String]` on
//  purpose (TM-02 row 1) — a parser that reached into `ProcessInfo` itself could never be handed its
//  own input, and the whole case would stay untestable. `ProcessInfo` is read once, in TM-01.
//

import Foundation

enum TestModeFlagParser {

	/// The one place a flag name is spelled. Names come from the approved dictionary and are not
	/// invented locally: `~/.claude/skills/xcuitest/reference/kit-flags.md`.
	private static let valueFlags: Set<String> = [
		"-adaptyLevelId",
		"-premiumAfter",
		"-noPremiumAfter",
		"-receiptDelay",
		"-storePurchaseDelay",
		"-paywallValue",
		"-remoteConfig",
	]

	private static let switchFlags: Set<String> = [
		"-premium",
		"-noPremium",
		"-adaptySilent",
		"-legacyPremium",
		"-noPremiumCache",
		"-receiptValid",
		"-receiptExpired",
		"-storePendingTransaction",
		"-storePurchaseSucceeds",
		"-storePurchaseCancelled",
		"-storePurchaseFails",
		"-storePurchasePending",
		"-storePurchaseUnavailable",
		"-storeRestoreSucceeds",
		"-storeRestoreFails",
		"-storeProductInfoHangs",
		"-storeHasTrial",
	]

	/// Every flag the package reads, for the one caller that needs the names without the parsing.
	static var allNames: Set<String> {
		valueFlags.union(switchFlags)
	}

	static func parse(_ arguments: [String]) -> TestModeFlags {
		var flags = TestModeFlags()

		// The mutually exclusive states are collected as they come and resolved by priority at the
		// end. Order of arguments therefore cannot decide the outcome (TM-03 rows 6, TM-05 row 4),
		// which is the difference between a suite that is green and one that is green through.
		var wantsGrant = false
		var wantsDenial = false
		var wantsSilence = false
		var receiptValid = false
		var receiptExpired = false
		var cancelled = false
		var pending = false
		var unavailable = false
		var purchaseFails = false
		var restoreSucceeds = false
		var restoreFails = false

		var index = 0
		while index < arguments.count {
			let name = arguments[index]
			index += 1
			guard name.hasPrefix("-") else {
				// Somebody else's value, or a flag of the app's own. Skipped without a word: the
				// package has no way to know them, and shouting about them would bury the names it
				// does know (TM-02 row 9).
				continue
			}
			if switchFlags.contains(name) {
				switch name {
					case "-premium": wantsGrant = true
					case "-noPremium": wantsDenial = true
					case "-adaptySilent": wantsSilence = true
					case "-legacyPremium": flags.legacyPremium = true
					case "-noPremiumCache": flags.noPremiumCache = true
					case "-receiptValid": receiptValid = true
					case "-receiptExpired": receiptExpired = true
					case "-storePendingTransaction": flags.pendingTransaction = true
					case "-storePurchaseSucceeds": break // The default; the flag exists to say so out loud.
					case "-storePurchaseCancelled": cancelled = true
					case "-storePurchasePending": pending = true
					case "-storePurchaseUnavailable": unavailable = true
					case "-storePurchaseFails": purchaseFails = true
					case "-storeRestoreSucceeds": restoreSucceeds = true
					case "-storeRestoreFails": restoreFails = true
					case "-storeProductInfoHangs": flags.productInfoHangs = true
					case "-storeHasTrial": flags.hasTrial = true
					default: break
				}
				continue
			}
			guard valueFlags.contains(name) else {
				// TM-02 row 9: a leading dash does not make a name ours. Apps pass their own flags
				// through the same array, so answering for every unknown one would put 8–15 lines into
				// the very list the apps assert on. The package answers for its own names only — and a
				// name the dictionary drops in a rename stops being ours the moment it is dropped, so
				// keeping the retired spelling listed is what would keep that rename visible.
				continue
			}
			// TM-02 row 4: the next element is a value only if there is one and it is not itself a
			// flag. Otherwise the flag is dropped and the next one stays intact rather than being
			// eaten as this one's value.
			guard index < arguments.count, !arguments[index].hasPrefix("-") else {
				flags.issues.append("test mode flag \(name) came without a value — the default stands")
				continue
			}
			let raw = arguments[index]
			index += 1
			switch name {
				case "-adaptyLevelId":
					flags.adaptyLevelId = raw
				case "-premiumAfter":
					flags.premiumAfter = seconds(raw, flag: name, into: &flags)
				case "-noPremiumAfter":
					flags.noPremiumAfter = seconds(raw, flag: name, into: &flags)
				case "-receiptDelay":
					flags.receiptDelay = seconds(raw, flag: name, into: &flags) ?? flags.receiptDelay
				case "-storePurchaseDelay":
					flags.purchaseDelay = seconds(raw, flag: name, into: &flags) ?? flags.purchaseDelay
				case "-paywallValue":
					insert(pair: raw, flag: name, into: &flags.paywallValues, issues: &flags.issues)
				case "-remoteConfig":
					insert(pair: raw, flag: name, into: &flags.remoteConfigValues, issues: &flags.issues)
				default:
					break
			}
		}

		// TM-03: silence beats both — a source either answers or it does not, and that question is
		// settled before what it answers. An explicit denial beats a grant, because the tests that
		// pass both are the ones checking that a denial overrides something.
		if wantsSilence {
			flags.adapty = .silent
		} else if wantsDenial {
			flags.adapty = .denial
		} else if wantsGrant {
			flags.adapty = .grant
		}

		// TM-04: an expired receipt beats a valid one, for the same reason a denial beats a grant —
		// the interesting test is the one where something is taken away.
		if receiptExpired {
			flags.receipt = .expired
		} else if receiptValid {
			flags.receipt = .valid
		}

		if cancelled {
			flags.purchase = .cancelled
		} else if pending {
			flags.purchase = .pending
		} else if unavailable {
			flags.purchase = .unavailable
		} else if purchaseFails {
			flags.purchase = .fails
		}

		if restoreFails {
			flags.restore = .fails
		} else if restoreSucceeds {
			flags.restore = .succeeds
		}

		return flags
	}

	/// A duration in seconds, or `nil` with a recorded cause. Negative is refused as firmly as
	/// non-numeric: a test that asked for it meant something, and silently reading it as zero would
	/// answer instantly where the test wanted a wait (TM-04 error contract).
	private static func seconds(_ raw: String, flag: String, into flags: inout TestModeFlags) -> TimeInterval? {
		guard let value = TimeInterval(raw), value.isFinite, value >= 0 else {
			flags.issues.append("test mode flag \(flag) got \"\(raw)\", which is not a number of seconds — the default stands")
			return nil
		}
		return value
	}

	/// One `key=value` pair. The key travels inside the value of a fixed flag rather than becoming a
	/// flag of its own, because `-closeDelay 3` would land in `NSArgumentDomain` and quietly shadow
	/// an app's `UserDefaults` key of the same name (TM-02 row 2). A repeated key keeps the last
	/// value (TM-02 row 6) — that is what assigning into a dictionary already does.
	private static func insert(pair: String, flag: String, into values: inout [String: Any], issues: inout [String]) {
		guard let separator = pair.firstIndex(of: "="), separator != pair.startIndex else {
			issues.append("test mode flag \(flag) got \"\(pair)\" instead of key=value — the pair is skipped; a boolean is written key=true")
			return
		}
		let key = String(pair[pair.startIndex ..< separator])
		let raw = String(pair[pair.index(after: separator)...])
		values[key] = typed(raw)
	}

	/// `Bool` → `Int` → `Double` → `String`, and `Int` strictly before `Double`. Not cosmetic: a call
	/// site reading `closeDelay` as an `Int` gets `nil` from `3.0 as? Int`, and the paywall draws its
	/// default while the test believes it set one (TM-02 row 3).
	private static func typed(_ raw: String) -> Any {
		if let value = Bool(raw) { return value }
		if let value = Int(raw) { return value }
		if let value = Double(raw) { return value }
		return raw
	}
}
