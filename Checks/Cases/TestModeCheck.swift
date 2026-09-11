//
//  TestModeCheck.swift
//  IntegrationKit
//
//  TM-01 through TM-07 — the rows of the approved test-mode schemas that can be reached without an
//  app. No XCTest: the parse is a pure function and every fake source is handed to the real
//  `PremiumService`, so a script is enough.
//  Run:  ./Checks/test-mode-check.sh
//

import Adapty
import Foundation

/// The real store's behaviour without `UserDefaults`: counts every write to `cached`, and a
/// notification only when the mirror flag actually changes.
final class CountingStore: PremiumStateStoring {
	private let lock = NSLock()
	private var state: PremiumState?
	private var flag: Bool
	private var notifications = 0

	init(cached: PremiumState? = nil, premium: Bool = false) {
		state = cached
		flag = premium
	}

	var notified: Int {
		lock.lock()
		defer { lock.unlock() }
		return notifications
	}

	var cached: PremiumState? {
		get {
			lock.lock()
			defer { lock.unlock() }
			return state
		}
		set {
			lock.lock()
			defer { lock.unlock() }
			state = newValue
		}
	}

	var premium: Bool {
		get {
			lock.lock()
			defer { lock.unlock() }
			return flag
		}
		set {
			lock.lock()
			defer { lock.unlock() }
			guard flag != newValue else { return }
			flag = newValue
			notifications += 1
		}
	}
}

@main
enum TestModeCheck {

	// MARK: - Harness

	/// Drains the main queue until `condition` holds or the deadline passes. Blocking on a semaphore
	/// would deadlock instead: every callback out of this layer is dispatched to the main queue.
	@discardableResult
	static func waitUntil(_ condition: () -> Bool, timeout: TimeInterval = 8) -> Bool {
		let deadline = Date().addingTimeInterval(timeout)
		while !condition(), Date() < deadline {
			RunLoop.main.run(until: Date().addingTimeInterval(0.01))
		}
		return condition()
	}

	static func pump(_ seconds: TimeInterval) {
		RunLoop.main.run(until: Date().addingTimeInterval(seconds))
	}

	/// Builds the whole premium layer on fake sources, exactly as the composition root does in a test
	/// run. The arbiter is the production one — that is the point of the layer.
	static func layer(
		_ arguments: [String],
		levels: Set<String> = ["premium"],
		productIds: Set<String> = ["sub.month"],
		cached: PremiumState? = nil,
		premium: Bool = false,
		sink: AnalyticsSink? = nil
	) -> (service: PremiumService, store: CountingStore, flags: TestModeFlags, adapty: FakeAdaptySource) {
		let flags = TestModeFlagParser.parse(arguments)
		let store = CountingStore(cached: cached, premium: premium)
		let adapty = FakeAdaptySource(flags: flags, levels: levels, productIds: productIds, sink: sink)
		let service = PremiumService(
			store: store,
			adapty: adapty,
			apple: FakeAppleStore(flags: flags, productIds: productIds),
			levels: levels,
			sourceTimeout: 5,
			productIds: productIds
		)
		return (service, store, flags, adapty)
	}

	static func lines(of path: String) -> [String] {
		let text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
		return text.split(separator: "\n").map(String.init)
	}

	// MARK: - Rows

	static func main() {
		// Unbuffered, and one line per row when asked: a row that hangs is otherwise a process with no
		// output at all, and the whole point of a check is to say which row broke.
		setvbuf(stdout, nil, _IONBF, 0)
		let verbose = ProcessInfo.processInfo.environment["VERBOSE"] != nil
		var passed = 0
		func row() {
			passed += 1
			if verbose { print("  row \(passed) ok") }
		}
		let temporary = NSTemporaryDirectory() + "integration-kit-test-mode-\(UUID().uuidString)"
		try? FileManager.default.createDirectory(atPath: temporary, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(atPath: temporary) }

		// MARK: TM-02 — the parse

		// 1. TM-02 row 7: three states, three names. Absence is a denial, and only `-adaptySilent`
		//    means silence — the difference PM-03 builds the Apple reserve on.
		assert(TestModeFlagParser.parse([]).adapty == .denial, "TM-02 row 7: no flag must mean an explicit denial")
		assert(TestModeFlagParser.parse(["-noPremium"]).adapty == .denial, "TM-02 row 7: -noPremium is a denial")
		assert(TestModeFlagParser.parse(["-adaptySilent"]).adapty == .silent, "TM-02 row 7: only -adaptySilent means silence")
		assert(TestModeFlagParser.parse(["-premium"]).adapty == .grant, "TM-02 row 7: -premium is a grant")
		row()

		// 2. TM-02 row 8: the legacy flag is the app's starting state, not a source's answer. The two
		//    live in different fields, which is the only reason a test can have both at once.
		let legacy = TestModeFlagParser.parse(["-legacyPremium", "-noPremium"])
		assert(legacy.legacyPremium, "TM-02 row 8: -legacyPremium must be its own field")
		assert(legacy.adapty == .denial, "TM-02 row 8: the Adapty answer must stay a denial alongside the legacy flag")
		row()

		// 3. TM-02 row 3: `Int` strictly before `Double`. A call site reading this as an `Int` is what
		//    the Logo Maker bug was — `3.0 as? Int` is nil and the paywall drew its default.
		let typed = TestModeFlagParser.parse(["-paywallValue", "closeDelay=3"])
		assert(typed.paywallValues["closeDelay"] as? Int == 3, "TM-02 row 3: closeDelay=3 must parse as Int 3, got \(String(describing: typed.paywallValues["closeDelay"]))")
		assert(typed.paywallValues["closeDelay"] as? Double == nil, "TM-02 row 3: an Int must not also answer as a Double")
		assert(TestModeFlagParser.parse(["-paywallValue", "hasTrial=true"]).paywallValues["hasTrial"] as? Bool == true, "TM-02: Bool comes before every number")
		assert(TestModeFlagParser.parse(["-paywallValue", "ratio=1.5"]).paywallValues["ratio"] as? Double == 1.5, "TM-02: a decimal falls through to Double")
		assert(TestModeFlagParser.parse(["-paywallValue", "name=main"]).paywallValues["name"] as? String == "main", "TM-02: anything else stays a String")
		row()

		// 4. TM-02 row 4: a value flag standing last, or followed by another flag, is dropped — and the
		//    next flag is NOT eaten as its value.
		let missing = TestModeFlagParser.parse(["-receiptDelay"])
		assert(missing.receiptDelay == 0.5, "TM-02 row 4: a value that never came leaves the default, got \(missing.receiptDelay)")
		assert(missing.issues.count == 1, "TM-02 row 4: the missing value must be recorded once, got \(missing.issues)")
		let eaten = TestModeFlagParser.parse(["-receiptDelay", "-premium"])
		assert(eaten.receiptDelay == 0.5, "TM-02 row 4: the next flag must not become this one's value")
		assert(eaten.adapty == .grant, "TM-02 row 4: -premium must survive the flag before it, got \(eaten.adapty)")
		row()

		// 5. TM-02 row 5: a pair without `=` is skipped and said out loud. A boolean is written
		//    `key=true`, never as a bare key.
		let unpaired = TestModeFlagParser.parse(["-paywallValue", "hasTrial"])
		assert(unpaired.paywallValues.isEmpty, "TM-02 row 5: a pair without = must be skipped")
		assert(unpaired.issues.count == 1, "TM-02 row 5: and recorded, got \(unpaired.issues)")
		row()

		// 6. TM-02 row 6: a repeated key keeps the last value.
		assert(TestModeFlagParser.parse(["-adaptyLevelId", "a", "-adaptyLevelId", "b"]).adaptyLevelId == "b", "TM-02 row 6: the last value must win")
		row()

		// 7. TM-02 row 9: the package answers for its own names only. A dash-prefixed name it does not
		//    know belongs to the app and passes without a word, exactly like a bare argument — a real
		//    run carries 8–15 of them, and one line each would bury the list the apps assert on.
		//    A malformed name of OURS still speaks up: that is rows 4 and 5 above.
		let unknown = TestModeFlagParser.parse(["-storePricesFail", "somefile.mp3", "-premium"])
		assert(unknown.issues.isEmpty, "TM-02 row 9: somebody else's flag must pass silently, got \(unknown.issues)")
		assert(unknown.adapty == .grant, "TM-02 row 9: the rest of the parse must carry on")
		row()

		// 8. TM-03 row 6 and TM-05 row 4: priority is written once, so both orders give one answer.
		assert(TestModeFlagParser.parse(["-premium", "-noPremium"]).adapty == .denial, "TM-03 row 6: -noPremium beats -premium")
		assert(TestModeFlagParser.parse(["-noPremium", "-premium"]).adapty == .denial, "TM-03 row 6: in both orders")
		assert(TestModeFlagParser.parse(["-adaptySilent", "-premium"]).adapty == .silent, "TM-03: silence beats both")
		assert(TestModeFlagParser.parse(["-storePurchaseCancelled", "-storePurchaseFails"]).purchase == .cancelled, "TM-05 row 4: cancelled beats failed")
		assert(TestModeFlagParser.parse(["-storePurchaseFails", "-storePurchaseCancelled"]).purchase == .cancelled, "TM-05 row 4: in both orders")
		assert(TestModeFlagParser.parse(["-receiptValid", "-receiptExpired"]).receipt == .expired, "TM-04: expired beats valid")
		assert(TestModeFlagParser.parse(["-storeRestoreSucceeds", "-storeRestoreFails"]).restore == .fails, "TM-05: restore failure beats success")
		row()

		// 9. TM-04 row 3 and TM-05 row 3: the defaults that make a barrier and a purchase-in-flight
		//    observable at all. An instant source hides both.
		let defaults = TestModeFlagParser.parse([])
		assert(defaults.receiptDelay == 0.5, "TM-04 row 3: the receipt answers after half a second by default, got \(defaults.receiptDelay)")
		assert(defaults.purchaseDelay == 1.5, "TM-05 row 3: the store takes 1.5s by default, got \(defaults.purchaseDelay)")
		assert(defaults.receipt == .unknown, "TM-04 row 1: no receipt flag means not checked, not 'no subscription'")
		assert(defaults.purchase == .succeeds, "TM-05: the default purchase succeeds")
		assert(defaults.restore == .nothingToRestore, "TM-05 row 5: the default restore finds nothing")
		row()

		// 10. TM-04 error contract: a delay that is not a number of seconds leaves the default and says
		//     so. Negative is refused as firmly — it would answer instantly where a wait was asked for.
		let badDelay = TestModeFlagParser.parse(["-receiptDelay", "abc", "-storePurchaseDelay", "-1"])
		assert(badDelay.receiptDelay == 0.5, "TM-04: a non-numeric delay leaves the default")
		assert(!badDelay.issues.isEmpty, "TM-04: and records the cause")
		row()

		// MARK: TM-07 — the sink

		// 11. TM-07 row 1: no path, no file, no exception. There is no default location.
		let silentAnalytics = SinkAnalytics(sink: nil)
		for index in 0 ..< 10 {
			silentAnalytics.logEvent("event_\(index)", properties: ["i": index])
		}
		silentAnalytics.setUserProperties(["k": "v"])
		let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: temporary)) ?? []
		assert(leftovers.isEmpty, "TM-07 row 1: a sink without a path must write nothing, found \(leftovers)")
		row()

		// 12. TM-07 rows 4 and 7: keys sorted, on disk immediately, identical text on a second run.
		let sortedPath = temporary + "/sorted.log"
		guard let sortedSink = AnalyticsSink(path: sortedPath) else {
			assertionFailure("TM-07: the sink must open a writable path")
			return
		}
		sortedSink.record("paywall_open", properties: ["b": 2, "a": 1, "c": 3])
		let firstLine = lines(of: sortedPath).first ?? ""
		assert(firstLine == #"paywall_open|{"a":1,"b":2,"c":3}"#, "TM-07 row 4: keys must be sorted, got \(firstLine)")
		let repeatPath = temporary + "/sorted-again.log"
		guard let repeatSink = AnalyticsSink(path: repeatPath) else {
			assertionFailure("TM-07: the second sink must open too")
			return
		}
		repeatSink.record("paywall_open", properties: ["c": 3, "a": 1, "b": 2])
		assert(lines(of: repeatPath).first == firstLine, "TM-07 row 4: the same data must give the same text")
		row()

		// 13. TM-07 row 6: a profile attribute is written with its prefix — the only channel a UI test
		//     has for user properties at all.
		let profilePath = temporary + "/profile.log"
		guard let profileSink = AnalyticsSink(path: profilePath) else {
			assertionFailure("TM-07: the profile sink must open")
			return
		}
		profileSink.record(profileValue: "main", key: "purchasePlace")
		SinkAnalytics(sink: profileSink).setUserProperties(["cohort": "b"])
		let profileLines = lines(of: profilePath)
		assert(profileLines.count == 2, "TM-07 row 6: both routes must write, got \(profileLines)")
		assert(profileLines[0] == #"profile_purchasePlace|{"value":"main"}"#, "TM-07 row 6: unexpected line \(profileLines[0])")
		assert(profileLines[1] == #"profile_cohort|{"value":"b"}"#, "TM-07 row 6: unexpected line \(profileLines[1])")
		row()

		// 14. TM-07 row 3: a hundred events from two queues are a hundred whole lines. Interleaved
		//     halves would fail to parse, which is the failure this row is about.
		let racePath = temporary + "/race.log"
		guard let raceSink = AnalyticsSink(path: racePath) else {
			assertionFailure("TM-07: the race sink must open")
			return
		}
		let group = DispatchGroup()
		for queue in 0 ..< 2 {
			DispatchQueue.global().async(group: group) {
				for index in 0 ..< 50 {
					raceSink.record("event", properties: ["queue": queue, "index": index])
				}
			}
		}
		group.wait()
		let raceLines = lines(of: racePath)
		assert(raceLines.count == 100, "TM-07 row 3: expected 100 lines, got \(raceLines.count)")
		assert(raceSink.count == 100, "TM-07 row 3: the sink's own counter must agree, got \(raceSink.count)")
		for line in raceLines {
			let payload = line.split(separator: "|", maxSplits: 1).last.map(String.init) ?? ""
			assert((try? JSONSerialization.jsonObject(with: Data(payload.utf8))) != nil, "TM-07 row 3: a line did not survive whole: \(line)")
		}
		row()

		// MARK: TM-03 — the Adapty answer

		// 15. TM-03 row 5: the level id travels inside the answer. The proof is the negative half — the
		//     same grant against a level the app did not configure is not premium.
		let levelled = FakeAdaptySource(flags: TestModeFlagParser.parse(["-premium", "-adaptyLevelId", "gold"]), levels: ["premium"], productIds: [], sink: nil)
		var goldProfile: AdaptyProfile?
		// Pumped, never blocked on a semaphore: `main()` is main-actor isolated, so a `Task` started
		// here runs on the main actor too and a blocking wait would be waiting on itself.
		Task { goldProfile = await levelled.profile() }
		assert(waitUntil({ goldProfile != nil }), "TM-03 row 5: the fake source must answer with a profile")
		guard let goldProfile else {
			assertionFailure("TM-03 row 5: the fake source must answer with a profile")
			return
		}
		assert(PremiumAccess(profile: goldProfile, levels: ["gold"]).isActive, "TM-03 row 5: -adaptyLevelId gold must grant the level 'gold'")
		assert(!PremiumAccess(profile: goldProfile, levels: ["premium"]).isActive, "TM-03 row 5: and must NOT grant a level the app configured instead")
		row()

		// 16. TM-03 row 1, rewritten for the arbitration rule of 2026-09-11. Adapty grants and never
		//     revokes, so `-noPremium` means "the source hands out nothing", not "premium is off": put
		//     a valid receipt on the table and the receipt decides, identically for a denial and for
		//     silence. What the flag still guarantees — and what every test using it actually wants —
		//     is the free state when nothing else is granting.
		let denied = layer(["-noPremium", "-receiptValid", "-receiptDelay", "0"])
		denied.service.start()
		waitUntil { denied.store.cached?.source == .apple }
		assert(denied.service.isPremium, "TM-03 row 1: a denial must not close access against a valid receipt")
		let silenced = layer(["-adaptySilent", "-receiptValid", "-receiptDelay", "0"])
		silenced.service.start()
		waitUntil { silenced.service.isPremium }
		assert(silenced.service.isPremium, "TM-03 row 1: with the source silent the receipt must be allowed to grant")
		assert(
			denied.store.cached?.source == silenced.store.cached?.source && denied.store.cached?.isPremium == silenced.store.cached?.isPremium,
			"TM-03 row 1: a denial and silence must resolve identically, got \(String(describing: denied.store.cached)) against \(String(describing: silenced.store.cached))"
		)
		let deniedAlone = layer(["-noPremium"])
		deniedAlone.service.start()
		pump(0.4)
		assert(deniedAlone.service.isPremium == false, "TM-03 row 1: -noPremium with nothing else granting must still mean free, got \(deniedAlone.service.isPremium)")
		row()

		// 17. TM-03 row 2: a deferred transition arrives through the profile push, the same entrance a
		//     real one uses — not as a write into the flag or the cache. One notification, not two.
		let deferred = layer(["-adaptySilent", "-receiptDelay", "0", "-premiumAfter", "1"])
		deferred.service.start()
		pump(0.4)
		assert(deferred.service.isPremium == false, "TM-03 row 2: before the transition there is no premium")
		assert(waitUntil({ deferred.service.isPremium }, timeout: 3), "TM-03 row 2: the deferred push must grant premium")
		assert(deferred.store.notified == 1, "TM-03 row 2: exactly one .premiumDidChange, got \(deferred.store.notified)")
		row()

		// 18. TM-03 row 3: silence is an immediate "unknown", not a callback that never comes. A source
		//     that hangs would cost every run the full five-second deadline.
		//     Measured through the barrier, which waits for BOTH sources: a silence that arrived as a
		//     callback that never comes would push this past the five-second deadline instead.
		let started = Date()
		let quiet = layer(["-adaptySilent", "-receiptValid", "-receiptDelay", "0"])
		quiet.service.start()
		assert(waitUntil({ quiet.service.isPremium }), "TM-03 row 3: the receipt must still produce a verdict")
		let elapsed = Date().timeIntervalSince(started)
		assert(elapsed < 2, "TM-03 row 3: a silent source must answer at once, not cost the deadline — took \(elapsed)s")
		row()

		// MARK: TM-04 — the Apple answer

		// 19. TM-04 row 1: no receipt flag is "not checked". A cached premium survives it — a `false`
		//     would have taken it away, which is the whole row.
		let hour: TimeInterval = 3600
		let kept = layer(["-adaptySilent"], cached: PremiumState(isPremium: true, source: .adapty, isVerified: true, expiresAt: Date() + hour), premium: true)
		kept.service.start()
		pump(1)
		assert(kept.service.isPremium, "TM-04 row 1: an unchecked receipt must not revoke a cached premium")
		row()

		// 20. TM-04 row 2: the answer carries a date, and against a standing local-purchase mark the
		//     date is the only thing that can close access. Both halves, so the date is doing the work
		//     rather than the flag.
		let expired = layer(["-adaptySilent", "-receiptExpired", "-receiptDelay", "0", "-storePurchaseDelay", "0"])
		expired.service.start()
		var expiredOutcome: PurchaseOutcome?
		expired.service.purchase("sub.month", placement: "main") { expiredOutcome = $0 }
		assert(waitUntil({ expiredOutcome != nil }), "TM-04 row 2: the purchase must settle")
		assert(expired.service.isPremium == false, "TM-04 row 2: an expired date must close access even right after a purchase")
		let valid = layer(["-adaptySilent", "-receiptValid", "-receiptDelay", "0", "-storePurchaseDelay", "0"])
		valid.service.start()
		var validOutcome: PurchaseOutcome?
		valid.service.purchase("sub.month", placement: "main") { validOutcome = $0 }
		assert(waitUntil({ validOutcome != nil }), "TM-04 row 2: the second purchase must settle")
		assert(valid.service.isPremium, "TM-04 row 2: the same purchase with a date in the future keeps access")
		row()

		// MARK: TM-05 — purchase, restore, prices

		// 21. TM-05 rows 1 and 9: the purchase goes through the arbiter, and the verdict is already
		//     stored by the time the completion runs — the app closes its paywall without waiting for
		//     a notification.
		let bought = layer(["-adaptySilent", "-receiptDelay", "0", "-storePurchaseDelay", "0"])
		bought.service.start()
		var premiumInsideCompletion: Bool?
		var boughtOutcome: PurchaseOutcome?
		bought.service.purchase("sub.month", placement: "main") { outcome in
			boughtOutcome = outcome
			premiumInsideCompletion = bought.service.isPremium
		}
		assert(waitUntil({ boughtOutcome != nil }), "TM-05 row 1: the purchase must settle")
		assert(boughtOutcome == .purchased, "TM-05: the default purchase succeeds, got \(String(describing: boughtOutcome))")
		assert(premiumInsideCompletion == true, "TM-05 row 9: isPremium must already be true inside the completion")
		assert(bought.store.cached?.source == .apple, "TM-05 row 1: the verdict must come from the arbiter, got \(String(describing: bought.store.cached?.source))")
		row()

		// 22. TM-05 row 2: the local-purchase mark holds access open against an Adapty denial that
		//     lands a second later. Without the mark it would be gone — that is the assertion.
		let marked = layer(["-adaptySilent", "-receiptDelay", "0", "-storePurchaseDelay", "0", "-noPremiumAfter", "1"])
		marked.service.start()
		var markedOutcome: PurchaseOutcome?
		marked.service.purchase("sub.month", placement: "main") { markedOutcome = $0 }
		assert(waitUntil({ markedOutcome != nil }), "TM-05 row 2: the purchase must settle")
		assert(marked.store.cached?.localPurchase == true, "TM-05 row 2: a successful purchase must leave the mark")
		pump(1.5)
		assert(marked.service.isPremium, "TM-05 row 2: a denial arriving after the purchase must not take it away")
		row()

		// 23. TM-05 row 5: the default restore finds nothing. "Nothing found but the user is premium"
		//     is assembled by pairing that default with `-premium`, and it stays the app's own rule.
		let restore = layer(["-adaptySilent", "-receiptDelay", "0"])
		restore.service.start()
		var restoreOutcome: RestoreOutcome?
		restore.service.restore { restoreOutcome = $0 }
		assert(waitUntil({ restoreOutcome != nil }), "TM-05 row 5: the restore must settle")
		assert(restoreOutcome == .nothingToRestore, "TM-05 row 5: the default restore finds nothing, got \(String(describing: restoreOutcome))")
		let restored = layer(["-adaptySilent", "-receiptDelay", "0", "-storeRestoreSucceeds"])
		restored.service.start()
		var restoredOutcome: RestoreOutcome?
		restored.service.restore { restoredOutcome = $0 }
		assert(waitUntil({ restoredOutcome != nil }), "TM-05 row 5: the second restore must settle")
		assert(restoredOutcome == .restored, "TM-05: -storeRestoreSucceeds restores")
		assert(restored.service.isPremium, "TM-05: a restore that found something grants access through the arbiter")
		row()

		// 24. TM-05 row 7: the catalogue exists without any flag asking for it, and is identical
		//     between runs. A paywall with placeholders makes every assertion on a button text pass
		//     against an empty string.
		let priced = layer([], productIds: ["sub.month", "sub.year"])
		var firstPrices: [PremiumProduct] = []
		priced.service.products(placement: "main") { firstPrices = $0 }
		assert(waitUntil({ !firstPrices.isEmpty }), "TM-05 row 7: prices must arrive without any flag")
		assert(firstPrices.count == 2, "TM-05 row 7: both configured ids must be priced, got \(firstPrices.map(\.id))")
		assert(firstPrices.allSatisfy { ($0.localizedPrice ?? "").isEmpty == false }, "TM-05 row 7: every price must be a real string")
		let againLayer = layer([], productIds: ["sub.month", "sub.year"])
		var secondPrices: [PremiumProduct] = []
		againLayer.service.products(placement: "main") { secondPrices = $0 }
		assert(waitUntil({ !secondPrices.isEmpty }), "TM-05 row 7: the second run must price too")
		assert(firstPrices.sorted { $0.id < $1.id } == secondPrices.sorted { $0.id < $1.id }, "TM-05 row 7: two runs must give identical prices")
		row()

		// 25. TM-05 row 8: `-storeHasTrial` is the store product's trial, `-paywallValue hasTrial=true`
		//     is a paywall value. Two behaviours, two flags, merging them is forbidden.
		let trial = layer(["-storeHasTrial"])
		var trialPrices: [PremiumProduct] = []
		trial.service.products(placement: "main") { trialPrices = $0 }
		assert(waitUntil({ !trialPrices.isEmpty }), "TM-05 row 8: prices must arrive")
		assert(trialPrices[0].introductoryOffer?.paymentMode == .freeTrial, "TM-05 row 8: -storeHasTrial must put a trial on the product")
		let paywallTrialValue: RemoteValue<Bool> = trial.service.remoteValue(placement: "main", key: "hasTrial")
		assert(paywallTrialValue.value == nil, "TM-05 row 8: -storeHasTrial must not set the paywall value")
		let valueTrial = layer(["-paywallValue", "hasTrial=true"])
		var valueTrialPrices: [PremiumProduct] = []
		valueTrial.service.products(placement: "main") { valueTrialPrices = $0 }
		assert(waitUntil({ !valueTrialPrices.isEmpty }), "TM-05 row 8: prices must arrive for the second half too")
		assert(valueTrialPrices[0].introductoryOffer == nil, "TM-05 row 8: the paywall value must not put a trial on the product")
		let flagTrialValue: RemoteValue<Bool> = valueTrial.service.remoteValue(placement: "main", key: "hasTrial")
		assert(flagTrialValue.value == true, "TM-05 row 8: -paywallValue hasTrial=true must set the paywall value")
		row()

		// 26. TM-05 row 6: the hang is the product listing alone. Premium, purchases and restore keep
		//     working in the same run, or one spinner test would take every other assertion with it.
		let hanging = layer(["-premium", "-receiptDelay", "0", "-storeProductInfoHangs"])
		hanging.service.start()
		assert(waitUntil({ hanging.service.isPremium }), "TM-05 row 6: premium must still arrive while the listing hangs")
		var hungPrices: [PremiumProduct]?
		hanging.service.products(placement: "main") { hungPrices = $0 }
		pump(0.5)
		assert(hungPrices == nil, "TM-05 row 6: the product listing must not answer at all")
		row()

		// MARK: TM-06 — substituted configuration values

		// 27. TM-06 row 1: two independent spaces. The same key in both flags is two unrelated values.
		let spaces = TestModeFlagParser.parse(["-paywallValue", "k=1", "-remoteConfig", "k=2"])
		let paywallSource = FakeAdaptySource(flags: spaces, levels: ["premium"], productIds: [], sink: nil)
		let firebase = FakeRemoteConfig(values: spaces.remoteConfigValues, defaults: [:])
		let fromPaywall: RemoteValue<Int> = paywallSource.remoteValue(placement: "main", key: "k")
		assert(fromPaywall.value == 1, "TM-06 row 1: the paywall space must answer 1, got \(String(describing: fromPaywall.value))")
		assert(firebase.int("k") == 2, "TM-06 row 1: the Firebase space must answer 2, got \(firebase.int("k"))")
		row()

		// 28. TM-06 row 2: silence puts out the whole paywall space at once — the paywall itself and
		//     every key with it. Both halves, because the pair is what shows it is the space and not
		//     one key.
		let dark = TestModeFlagParser.parse(["-adaptySilent", "-paywallValue", "paywallName=main"])
		let darkSource = FakeAdaptySource(flags: dark, levels: ["premium"], productIds: [], sink: nil)
		assert(darkSource.hasPaywall(placement: "main") == false, "TM-06 row 2: a silent source has no paywall")
		let darkValue: RemoteValue<String> = darkSource.remoteValue(placement: "main", key: "paywallName")
		assert(darkValue.value == nil, "TM-06 row 2: and no value either, got \(String(describing: darkValue.value))")
		assert(darkValue.isPending, "TM-06 row 2: the reason must be 'not ready', not 'not set'")
		row()

		// 29. TM-06 row 4: without a flag Firebase answers the default the app registered — which is
		//     exactly what a live Firebase does before its first fetch lands.
		let registered: [String: NSObject] = ["newPaywall": NSNumber(value: false), "title": NSString(string: "old")]
		let defaulted = FakeRemoteConfig(values: [:], defaults: registered)
		assert(defaulted.bool("newPaywall") == false, "TM-06 row 4: the registered default must answer")
		assert(defaulted.string("title") == "old", "TM-06 row 4: including strings")
		let overridden = FakeRemoteConfig(values: TestModeFlagParser.parse(["-remoteConfig", "newPaywall=true"]).remoteConfigValues, defaults: registered)
		assert(overridden.bool("newPaywall"), "TM-06 row 4: and the flag must override it")
		assert(overridden.string("title") == "old", "TM-06 row 4: without touching the keys it did not name")
		row()

		// 30. TM-06 row 5: an unknown KEY is silent — keys belong to the app and the package has
		//     nothing to check them against. Since the decision of 2026-09-11 an unknown FLAG is silent
		//     for the same reason: the name is not ours either. What still speaks is a name of OURS
		//     used wrongly, and that is the contrast the row now draws.
		ConfigurationIssues.shared.reset()
		let unknownKey = TestModeFlagParser.parse(["-paywallValue", "somethingNobodyKnows=1"])
		assert(unknownKey.issues.isEmpty, "TM-06 row 5: an unknown key must not be recorded, got \(unknownKey.issues)")
		assert(TestModeFlagParser.parse(["-storePricesFail"]).issues.isEmpty, "TM-06 row 5: nor an unknown flag")
		assert(TestModeFlagParser.parse(["-paywallValue", "somethingNobodyKnows"]).issues.count == 1, "TM-06 row 5: but our own flag used wrongly must be")
		row()

		// MARK: TM-01 — activation

		// 31. TM-01 row 1 and invariant 2: an active test mode always leaves a line apps read in
		//     release too. Plus TM-03 row 7: the stored verdict is wiped before anything reads it.
		ConfigurationIssues.shared.reset()
		let store = UserDefaultsPremiumStore()
		store.cached = PremiumState(isPremium: true, source: .adapty, isVerified: true, expiresAt: Date() + hour)
		let graph = TestModeGraph.make(
			arguments: ["-noPremiumCache", "-legacyPremium", "-receiptDelay"],
			environment: [:],
			levels: ["premium"],
			productIds: ["sub.month"],
			remoteConfigDefaults: [:]
		)
		let issues = ConfigurationIssues.shared.all
		assert(issues.contains { $0.contains("TEST MODE") }, "TM-01 row 1: the active mode must announce itself, got \(issues)")
		// A flag of OURS used wrongly — an unrecognised name is somebody else's and passes silently
		// since the decision of 2026-09-11, so it can no longer stand for "a parse issue travels".
		assert(issues.contains { $0.contains("-receiptDelay") }, "TM-01 row 3: a parse issue must reach the same list, got \(issues)")
		assert(graph.store.cached == nil, "TM-03 row 7: -noPremiumCache must wipe the stored verdict before start")
		assert(graph.store.premium, "TM-02 row 8: -legacyPremium must leave the app's old flag on")
		store.cached = nil
		store.premium = false
		row()

		// 32. TM-01 row 7 and TM-07 row 1: the mode on with no arguments must look, to a unit run, like
		//     the layer that is simply switched off today — a denial from Adapty, a silent receipt, and
		//     nothing written anywhere.
		ConfigurationIssues.shared.reset()
		let bare = TestModeGraph.make(arguments: [], environment: [:], levels: ["premium"], productIds: [], remoteConfigDefaults: [:])
		assert(bare.flags.adapty == .denial, "TM-01 row 7: the default answer is a denial")
		assert(bare.flags.receipt == .unknown, "TM-01 row 7: and an unchecked receipt")
		let stillEmpty = (try? FileManager.default.contentsOfDirectory(atPath: temporary)) ?? []
		assert(stillEmpty.count == 4, "TM-07 row 1: a run without a sink path must add no files, found \(stillEmpty)")
		row()

		print("TestMode: \(passed)/32 OK")
	}
}
