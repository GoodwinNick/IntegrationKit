//
//  FirebaseAnalyticsCheck.swift
//  IntegrationKit
//
//  Written from the approved schemas FA-01…FA-05 (`Модулі/Сервіси/FirebaseAnalytics/` in the vault),
//  not from the code — the mirror did not exist when this file was written, so every assert is red
//  until `FirebaseAnalyticsMirror` and its wiring into `AmplitudeAnalytics` land. Same shape as the
//  other checks: no XCTest, no Xcode project, every row runs, every failure is collected, the
//  summary at the end exits non-zero.
//
//  What this covers, by schema row (the numbers are the rows of each `FA-0x Ризики` table):
//    FA-01 r1 r2 r3 r5      collection flag, "Firebase is not up", test run
//    FA-02 r1 r2 r3 r4 r5 r6 r7 r8 r9 r11 r12   the event path and the sanitiser
//    FA-03 r1 r2 r3 r5 r6 r7 r8                 user properties and user id
//    FA-04 (the mirror half)  `logTransaction` gate — the call sites are `AdaptyServiceCheck` (T-FA04*)
//    FA-05 r2 r3 r6                             the Firebase id on its way to Adapty
//    AN-01 r12, AN-02 r6, AN-03 r7              the boundary with `AmplitudeAnalytics`
//
//  Deliberately without an assert, per the schemas themselves:
//    FA-01 r4 (the automatic-events window), r6 (`-ObjC`) — documentation and `buildhost-check.sh`;
//    FA-02 r10 (an app that still calls `Analytics.logEvent` itself) — documentation only;
//    FA-03 r4 (more than 25 property names) — the package cannot count the app's own;
//    FA-04 r2 r6 r7 — live DebugView only; r3 r4 r5 are `AdaptyServiceCheck`; r8 is
//    `premium-storekit-check.sh`; r9 is `test-mode-check.sh` and `integration-kit-check.sh`;
//    FA-05 r4 (the Adapty queue, AD-06 r13), r5 (a double write by an app), r7 (AD-06 r15).
//
//  Built without `-D DEBUG` on purpose, like `amplitude-analytics-check.sh`: that is what makes
//  `debugLogSink` (`DebugLog.swift:25-27`) the readable destination the log asserts rely on. The
//  error format is `[IntegrationKit][FirebaseAnalytics][error] text`; info is
//  `[IntegrationKit][FirebaseAnalytics] text` (`DebugLog.swift:31-35`).
//  Run:  ./Checks/firebase-analytics-check.sh
//

import AmplitudeSwift
import AppTrackingTransparency
import FirebaseAnalytics
import FirebaseCore
import Foundation

@main
enum FirebaseAnalyticsCheck {
	static var failures: [String] = []
	static var log: [String] = []
	static var assertCount = 0

	static let infoPrefix = "[IntegrationKit][FirebaseAnalytics] "
	static let errorPrefix = "[IntegrationKit][FirebaseAnalytics][error] "
	static let firstOpenTrackedKey = "IntegrationKit.amplitude.firstOpenTracked"

	/// The five user-property names the package writes itself (FA-03 r3). If a sixth is ever added
	/// it has to be added here too — the assert below then proves Firebase would accept it.
	static let packageProperties = ["environment", "status", "media_source", "campaign_name", "deep_link_value"]

	static func check(_ condition: @autoclosure () -> Bool, _ message: @autoclosure () -> String) {
		assertCount += 1
		guard !condition() else { return }
		let text = message()
		failures.append(text)
		print("FAILED: \(text)")
	}

	/// One row's setup must not leak into the next: both SDK stubs, the issue list, the captured log
	/// and the first-open gate.
	static func reset() {
		Analytics.reset()
		FirebaseApp.reset()
		Amplitude.reset()
		ConfigurationIssues.shared.reset()
		UserDefaults.standard.removeObject(forKey: firstOpenTrackedKey)
		log = []
	}

	/// Firebase is up — what `FirebaseIntegration.configure(isDebug:)` does in the app.
	static func up() {
		FirebaseApp.configure()
	}

	static func text(_ count: Int, _ character: Character = "x") -> String {
		String(repeating: character, count: count)
	}

	static var errorLog: [String] {
		log.filter { $0.hasPrefix(errorPrefix) }
	}

	static var infoLog: [String] {
		log.filter { $0.hasPrefix(infoPrefix) }
	}

	static func firebaseIssues() -> [String] {
		ConfigurationIssues.shared.all.filter { $0.contains("Firebase is not up") }
	}

	/// The parameters of the LAST event of that name that reached Firebase, `[:]` when it carried none,
	/// `nil` when no such event reached it at all.
	static func firebaseParams(_ name: String) -> [String: Any]? {
		guard let event = Analytics.loggedEvents.last(where: { $0.name == name }) else { return nil }
		return event.parameters ?? [:]
	}

	static func main() {
		debugLogSink = { log.append($0) }

		let sections: [(String, () -> Void)] = [
			("FA-01 collection and readiness", fa01),
			("FA-02 event", fa02),
			("FA-03 user profile", fa03),
			("FA-04 transaction gate", fa04),
			("FA-05 instance id", fa05),
			("AN boundary", amplitudeBoundary),
		]
		for (name, section) in sections {
			fputs("· \(name)\n", stderr)
			section()
		}

		if failures.isEmpty {
			print("FirebaseAnalytics FA-01…FA-05 and the AN boundary: \(assertCount) asserts OK")
		} else {
			print("\(failures.count) of \(assertCount) assert(s) failed:")
			for failure in failures {
				print("  - \(failure)")
			}
			exit(1)
		}
	}

	// MARK: - FA-01: collection and readiness

	static func fa01() {
		// FA-01 r1 — Firebase is not up on a normal launch. Nothing reaches the SDK, and the cause
		// lands in `configurationIssues` ONCE, not once per call (the second `configure` and the event
		// below are two more chances to write it twice).
		reset()
		let r1 = FirebaseAnalyticsMirror()
		r1.configure(isTestsRunning: false)
		r1.configure(isTestsRunning: false)
		r1.logEvent("any_event", properties: nil)
		check(Analytics.collectionEnabledCalls.isEmpty && Analytics.loggedEvents.isEmpty,
		      "FA-01 r1: with Firebase down nothing may reach the SDK — flag calls \(Analytics.collectionEnabledCalls), events \(Analytics.loggedEvents.count)")
		check(firebaseIssues().count == 1,
		      "FA-01 r1: \"Firebase is not up\" must be recorded exactly once however many calls follow — got \(firebaseIssues())")
		check(firebaseIssues().first?.contains("FirebaseIntegration.configure()") == true,
		      "FA-01 r1: the issue must tell the integrator what to call — got \(firebaseIssues())")

		// FA-01 r2 — the same state in a TEST RUN is not a complaint: the mirror is not in the chain
		// there, and an app whose test build skips Firebase must not see its own assert on
		// `configurationIssues` go red for a reason it cannot act on.
		reset()
		let r2 = FirebaseAnalyticsMirror()
		r2.configure(isTestsRunning: true)
		check(ConfigurationIssues.shared.all.isEmpty,
		      "FA-01 r2: a test run without Firebase must leave no issue — got \(ConfigurationIssues.shared.all)")
		check(Analytics.collectionEnabledCalls.isEmpty,
		      "FA-01 r2: a test run without Firebase must not reach the SDK — got \(Analytics.collectionEnabledCalls)")

		// FA-01 r3 — the flag is written on EVERY launch, in both directions. A test run that only ever
		// switched collection off would leave the device off for every build installed after it.
		reset()
		up()
		let r3 = FirebaseAnalyticsMirror()
		r3.configure(isTestsRunning: true)
		r3.configure(isTestsRunning: false)
		check(Analytics.collectionEnabledCalls == [false, true],
		      "FA-01 r3: a test run writes false and the next normal launch writes true — got \(Analytics.collectionEnabledCalls)")
		check(infoLog.contains { $0.contains("collection disabled") } && infoLog.contains { $0.contains("collection enabled") },
		      "FA-01: the log must say which way the flag went and why — got \(infoLog)")

		// A debug build collects like a release one: without it there is no DebugView, and the
		// `environment` property is what tells the two apart (FA-01 case file, "Схема").
		reset()
		up()
		FirebaseAnalyticsMirror().configure(isTestsRunning: false)
		check(Analytics.collectionEnabledCalls == [true],
		      "FA-01: a normal launch enables collection explicitly — got \(Analytics.collectionEnabledCalls)")
	}

	// MARK: - FA-02: event

	static func fa02() {
		// FA-02 r1 — Firebase is not up: the event does not reach it, and the cause is written once.
		reset()
		let r1 = FirebaseAnalyticsMirror()
		for _ in 0..<3 { r1.logEvent("any_event", properties: ["k": "v"]) }
		check(Analytics.loggedEvents.isEmpty, "FA-02 r1: with Firebase down no event may reach the SDK — got \(Analytics.loggedEvents.count)")
		check(firebaseIssues().count == 1, "FA-02 r1: the cause must be recorded once, not per event — got \(firebaseIssues())")

		reset()
		up()
		let mirror = FirebaseAnalyticsMirror()

		// FA-02 r2 — a string over 100 characters. Firebase drops the whole parameter, so the mirror
		// cuts it to 100 — and says so with the key and both lengths. The short sibling is untouched.
		mirror.logEvent("long_value", properties: ["referrer": text(143), "short": "ok"])
		let r2 = firebaseParams("long_value")
		check((r2?["referrer"] as? String)?.count == 100,
		      "FA-02 r2: a 143-character value must reach Firebase as exactly 100 — got \((r2?["referrer"] as? String)?.count.description ?? "missing")")
		check((r2?["short"] as? String) == "ok", "FA-02 r2: a value inside the limit must pass untouched — got \(String(describing: r2?["short"]))")
		check(infoLog.contains { $0.contains("referrer") && $0.contains("143") && $0.contains("100") },
		      "FA-02 r2: the cut must leave an info line with the key and both lengths — got \(infoLog)")
		check(infoLog.contains { $0.contains("long_value") && $0.contains("short") },
		      "FA-02: the log must carry the event name and the dictionary that went — got \(infoLog)")

		// FA-02 r3 — the unit is UTF-16 code units (what `NSString.length` counts), and a character is
		// never split. A hundred Cyrillic letters are 100 units and stay whole; 99 letters plus an emoji
		// are 101 units, so the emoji goes — whole, not as half a surrogate pair.
		mirror.logEvent("cyrillic", properties: ["v": text(100, "ж")])
		check((firebaseParams("cyrillic")?["v"] as? String) == text(100, "ж"),
		      "FA-02 r3: 100 Cyrillic letters are 100 UTF-16 units and must pass whole")
		mirror.logEvent("emoji", properties: ["v": text(99, "a") + "😀"])
		check((firebaseParams("emoji")?["v"] as? String) == text(99, "a"),
		      "FA-02 r3: an emoji that would cross the limit must be dropped whole, got \(String(describing: firebaseParams("emoji")?["v"]))")

		// FA-02 r4 — the limit is 100 for every property, Analytics 360's 500 included: the 101st
		// character is gone.
		mirror.logEvent("edge", properties: ["v": text(101)])
		check((firebaseParams("edge")?["v"] as? String)?.count == 100, "FA-02 r4: the 101st character must be cut")

		// FA-02 r5 and r6 — a name Firebase would drop never reaches it (the master's decision of
		// 2026-10-01: a dropped event comes back as a noise `error` event in the dashboard). Reserved
		// names included — an app that names its first-open event `first_open` lands here.
		let badNames = ["bad name", "first_open", "session_start", "error", text(41, "n"), "firebase_x", "google_x", "ga_x", "1abc", "_x", "x-y", ""]
		for bad in badNames {
			Analytics.reset()
			log = []
			mirror.logEvent(bad, properties: ["k": "v"])
			check(Analytics.loggedEvents.isEmpty,
			      "FA-02 r5/r6: an event named \"\(bad)\" must not reach Firebase — got \(Analytics.loggedEvents.map(\.name))")
			check(errorLog.contains { bad.isEmpty || $0.contains(bad) },
			      "FA-02 r5/r6: an event named \"\(bad)\" must leave an error line naming it — got \(errorLog)")
		}
		Analytics.reset()
		for good in ["level_up", "A1_b", text(40, "n"), "screen_view"] {
			mirror.logEvent(good, properties: nil)
		}
		check(Analytics.loggedEvents.map(\.name) == ["level_up", "A1_b", text(40, "n"), "screen_view"],
		      "FA-02 r5: valid names — 40 characters included, `screen_view` which is NOT reserved — must pass, got \(Analytics.loggedEvents.map(\.name))")

		// FA-02 r7 — more than 25 parameters: ALL go (which ones Firebase would drop is not documented,
		// and choosing for it is not the sanitiser's job — decision 2026-10-01), with an error line
		// that carries the count.
		Analytics.reset()
		log = []
		var many: [String: Any] = [:]
		for index in 0..<26 { many["p\(index)"] = index }
		mirror.logEvent("many", properties: many)
		check(firebaseParams("many")?.count == 26, "FA-02 r7: all 26 parameters must go as given — got \(firebaseParams("many")?.count.description ?? "no event")")
		check(errorLog.contains { $0.contains("26") }, "FA-02 r7: the count must be in an error line — got \(errorLog)")

		// FA-02 r8 — a key Firebase would drop: THAT parameter does not go, the rest of the event does.
		// The 40-character key is the boundary and passes.
		Analytics.reset()
		log = []
		mirror.logEvent("keys", properties: ["ok": 1, "a.b": 2, "9x": 3, "firebase_k": 4, text(41, "k"): 5, text(40, "k"): 6])
		check(Set(firebaseParams("keys")?.keys.map { $0 } ?? []) == Set(["ok", text(40, "k")]),
		      "FA-02 r8: only the valid keys may reach Firebase — got \(firebaseParams("keys")?.keys.sorted() ?? [])")
		check(errorLog.contains { $0.contains("a.b") }, "FA-02 r8: a dropped key must be named in an error line — got \(errorLog)")

		// FA-02 r9 — what Firebase accepts is String, Int and Double only. A Bool becomes text, an
		// `NSNumber(1)` stays a NUMBER (a Swift `as? Bool` would also match it — the trap this row is
		// about), anything else is `String(describing:)`, and `NSNull` has no representation at all.
		Analytics.reset()
		log = []
		let date = Date(timeIntervalSince1970: 0)
		mirror.logEvent("types", properties: [
			"yes": true, "no": false, "int": 7, "double": 1.5, "one": NSNumber(value: 1),
			"date": date, "list": ["a"], "null": NSNull(), "text": "plain",
		])
		let r9 = firebaseParams("types") ?? [:]
		check((r9["yes"] as? String) == "true" && (r9["no"] as? String) == "false",
		      "FA-02 r9: a Bool must go as \"true\"/\"false\" — got \(String(describing: r9["yes"])), \(String(describing: r9["no"]))")
		check((r9["int"] as? Int) == 7 && (r9["double"] as? Double) == 1.5,
		      "FA-02 r9: numbers go as numbers — got \(String(describing: r9["int"])), \(String(describing: r9["double"]))")
		check((r9["one"] as? String) == nil && (r9["one"] as? Int) == 1,
		      "FA-02 r9: NSNumber(1) is a number, not the Bool `true` — got \(String(describing: r9["one"]))")
		check((r9["date"] as? String) == String(describing: date) && (r9["list"] as? String) == String(describing: ["a"]),
		      "FA-02 r9: other types go as String(describing:) — got \(String(describing: r9["date"])), \(String(describing: r9["list"]))")
		check(r9["null"] == nil && (r9["text"] as? String) == "plain",
		      "FA-02 r9: NSNull has no Firebase form and must be left out — got \(String(describing: r9["null"]))")
		check(errorLog.contains { $0.contains("null") }, "FA-02 r9: the left-out pair must be named in an error line — got \(errorLog)")

		// No properties, or none given: an event without parameters, never a crash and never `nil`
		// inside a dictionary.
		Analytics.reset()
		mirror.logEvent("bare", properties: nil)
		mirror.logEvent("bare_empty", properties: [:])
		check((firebaseParams("bare") ?? ["x": 1]).isEmpty && (firebaseParams("bare_empty") ?? ["x": 1]).isEmpty,
		      "FA-02: an event with no properties must reach Firebase with no parameters")

		// FA-02 r11 — two threads at once. The sanitiser keeps no state, so the only thing to prove is
		// that nothing is lost or trapped.
		Analytics.reset()
		DispatchQueue.concurrentPerform(iterations: 50) { index in
			mirror.logEvent("concurrent", properties: ["i": index])
		}
		check(Analytics.loggedEvents.count == 50, "FA-02 r11: 50 concurrent events must all arrive — got \(Analytics.loggedEvents.count)")
	}

	// MARK: - FA-03: user profile

	static func fa03() {
		// FA-03 r1 — Firebase is not up: neither a property nor an id reaches it, one issue.
		reset()
		let r1 = FirebaseAnalyticsMirror()
		for _ in 0..<3 {
			r1.setUserProperties(["status": "organic"])
			r1.setUserId("id-1")
		}
		check(Analytics.userProperties.isEmpty && Analytics.userIDs.isEmpty,
		      "FA-03 r1: with Firebase down nothing may reach the SDK — got \(Analytics.userProperties.count) properties, \(Analytics.userIDs.count) ids")
		check(firebaseIssues().count == 1, "FA-03 r1: the cause must be recorded once — got \(firebaseIssues())")

		reset()
		up()
		let mirror = FirebaseAnalyticsMirror()

		// FA-03 r2 — a value over 36 characters is cut for Firebase.
		mirror.setUserProperties(["campaign_name": text(60)])
		check(Analytics.userProperties.last?.name == "campaign_name" && Analytics.userProperties.last?.value?.count == 36,
		      "FA-03 r2: a 60-character value must reach Firebase as exactly 36 — got \(String(describing: Analytics.userProperties.last))")
		check(infoLog.contains { $0.contains("campaign_name") && $0.contains("60") && $0.contains("36") },
		      "FA-03 r2: the cut must leave an info line with the key and both lengths — got \(infoLog)")

		// FA-03 r3 — every name the package itself writes passes Firebase's rules; the rules' own
		// violations do not reach it, and are named. Not renamed: they are not sent (decision
		// 2026-10-01, generalised from events to properties).
		Analytics.reset()
		for name in packageProperties { mirror.setUserProperties([name: "v"]) }
		check(Analytics.userProperties.map(\.name) == packageProperties,
		      "FA-03 r3: the package's own five names must all pass — got \(Analytics.userProperties.map(\.name))")
		let badProperties = ["user_id", "first_open_time", "last_deep_link_referrer", text(25, "n"), "firebase_x", "google_x", "ga_x", "1a", "a b"]
		for bad in badProperties {
			Analytics.reset()
			log = []
			mirror.setUserProperties([bad: "v"])
			check(Analytics.userProperties.isEmpty, "FA-03 r3: a property named \"\(bad)\" must not reach Firebase — got \(Analytics.userProperties.map(\.name))")
			check(errorLog.contains { $0.contains(bad) }, "FA-03 r3: a property named \"\(bad)\" must leave an error line naming it — got \(errorLog)")
		}
		Analytics.reset()
		mirror.setUserProperties([text(24, "n"): "v"])
		check(Analytics.userProperties.count == 1, "FA-03 r3: a 24-character name is the boundary and passes")

		// FA-03 r5 — Firebase takes a String and nothing else.
		Analytics.reset()
		log = []
		let date = Date(timeIntervalSince1970: 0)
		mirror.setUserProperties(["n": 1, "d": 1.5, "b": true, "when": date, "s": "plain"])
		let values = Dictionary(uniqueKeysWithValues: Analytics.userProperties.map { ($0.name, $0.value) })
		check(values["n"] == "1" && values["d"] == "1.5" && values["b"] == "true" && values["s"] == "plain",
		      "FA-03 r5: numbers, Bool and text must all go as their text form — got \(values)")
		check(values["when"] == String(describing: date), "FA-03 r5: a Date goes as String(describing:) — got \(String(describing: values["when"]))")
		check(infoLog.contains { $0.contains("UserProperty: s | value: plain") },
		      "FA-03: the log must show one line per pair, `UserProperty: <key> | value: <value>` — got \(infoLog)")

		// FA-03 r8 — NSNull removes the property in Firebase (`nil`, `FIRAnalytics.h:85-86`).
		Analytics.reset()
		mirror.setUserProperties(["gone": NSNull()])
		check(Analytics.userProperties.count == 1 && Analytics.userProperties[0].name == "gone" && Analytics.userProperties[0].value == nil,
		      "FA-03 r8: NSNull must remove the property in Firebase — got \(Analytics.userProperties)")

		// FA-03 r6 — the id. Empty and over-256 never reach Firebase (an empty one joins every
		// profile to nobody; a cut one would join different users into one); 256 is the boundary.
		Analytics.reset()
		log = []
		mirror.setUserId("")
		mirror.setUserId(text(257))
		check(Analytics.userIDs.isEmpty, "FA-03 r6: an empty id and a 257-character id must not reach Firebase — got \(Analytics.userIDs.count) call(s)")
		check(errorLog.count >= 2, "FA-03 r6: both refusals must leave an error line — got \(errorLog)")
		mirror.setUserId(text(256))
		mirror.setUserId("id-1")
		check(Analytics.userIDs == [text(256), "id-1"], "FA-03 r6: a 256-character id is the boundary and passes — got \(Analytics.userIDs.map { $0?.count ?? -1 })")
		check(infoLog.contains { $0.contains("UserId: id-1") }, "FA-03: the log must show the id itself — got \(infoLog)")
	}

	// MARK: - FA-04: transaction gate (the mirror half)

	static func fa04() {
		// The call sites — Adapty's `.success`, StoreKit's `.success(.verified)` — are asserted where
		// those services run: `AdaptyServiceCheck` (T-FA04*). What belongs here is the gate they both
		// go through: Firebase up passes the value to the SDK function it was handed, Firebase down
		// does not, and neither changes the caller's own result.
		reset()
		up()
		FirebaseAnalyticsMirror().logTransaction("tx-1", send: Analytics.logTransaction)
		check(Analytics.transactions == ["tx-1"], "FA-04: with Firebase up the transaction must reach the SDK — got \(Analytics.transactions)")
		check(infoLog.contains { $0.contains("tx-1") }, "FA-04: the log must show which transaction went — got \(infoLog)")

		// FA-04 r1 — Firebase is not up: the SDK is not touched, one issue.
		reset()
		let down = FirebaseAnalyticsMirror()
		down.logTransaction("tx-2", send: Analytics.logTransaction)
		down.logTransaction("tx-3", send: Analytics.logTransaction)
		check(Analytics.transactions.isEmpty, "FA-04 r1: with Firebase down no transaction may reach the SDK — got \(Analytics.transactions)")
		check(firebaseIssues().count == 1, "FA-04 r1: the cause must be recorded once — got \(firebaseIssues())")
	}

	// MARK: - FA-05: instance id

	static func fa05() {
		// FA-05 r2 — `nil` first (the id is not ready yet), a value on the next try: nothing is
		// delivered the first time, the value is delivered the second, and `nil` is a log line, not an
		// issue.
		reset()
		up()
		let mirror = FirebaseAnalyticsMirror()
		var delivered: [String] = []
		Analytics.stubAppInstanceID = nil
		mirror.syncAppInstanceId { delivered.append($0) }
		check(delivered.isEmpty, "FA-05 r2: a nil id must deliver nothing — got \(delivered)")
		check(infoLog.contains { $0.contains("nil") }, "FA-05: the read must be logged including nil — got \(infoLog)")
		Analytics.stubAppInstanceID = "fid-1"
		mirror.syncAppInstanceId { delivered.append($0) }
		check(delivered == ["fid-1"], "FA-05 r2: the id that arrived late must be delivered on the next try — got \(delivered)")

		// FA-05 r6 (second half) — the same id again is not delivered again.
		mirror.syncAppInstanceId { delivered.append($0) }
		check(delivered == ["fid-1"], "FA-05 r6: an unchanged id must not be sent twice in one process — got \(delivered)")
		// …and a CHANGED one is (the app reset Firebase's analytics data).
		Analytics.stubAppInstanceID = "fid-2"
		mirror.syncAppInstanceId { delivered.append($0) }
		check(delivered == ["fid-1", "fid-2"], "FA-05 r6: a changed id must follow it — got \(delivered)")

		// FA-05 r3 — a consent that forbids analytics storage answers nil forever. Three tries, no
		// delivery, and no new line in `configurationIssues`: this is not a misconfiguration.
		reset()
		up()
		let denied = FirebaseAnalyticsMirror()
		var deniedDeliveries: [String] = []
		Analytics.stubAppInstanceID = nil
		for _ in 0..<3 { denied.syncAppInstanceId { deniedDeliveries.append($0) } }
		check(deniedDeliveries.isEmpty, "FA-05 r3: a permanent nil must deliver nothing — got \(deniedDeliveries)")
		check(ConfigurationIssues.shared.all.isEmpty, "FA-05 r3: a nil id is not a configuration issue — got \(ConfigurationIssues.shared.all)")

		// An empty string is "no id" too — it joins nothing, and Adapty must never get one from the kit.
		Analytics.stubAppInstanceID = ""
		denied.syncAppInstanceId { deniedDeliveries.append($0) }
		check(deniedDeliveries.isEmpty, "FA-05: an empty id must not be delivered — got \(deniedDeliveries)")

		// FA-05 r1 — Firebase is not up: the SDK is not even asked.
		reset()
		let down = FirebaseAnalyticsMirror()
		var downDeliveries: [String] = []
		down.syncAppInstanceId { downDeliveries.append($0) }
		check(downDeliveries.isEmpty && Analytics.appInstanceIDReads == 0,
		      "FA-05 r1: with Firebase down the id must not be read — deliveries \(downDeliveries), reads \(Analytics.appInstanceIDReads)")
	}

	// MARK: - The boundary with AmplitudeAnalytics (AN-01 r12, AN-02 r6, AN-03 r7)

	static func amplitudeBoundary() {
		// AN-02 r6 / FA-02 r2 — Amplitude gets the ORIGINAL, Firebase the sanitised copy. A Bool stays
		// a Bool for Amplitude and becomes text for Firebase; a 143-character value stays 143 for
		// Amplitude and becomes 100.
		reset()
		up()
		let a = AmplitudeAnalytics()
		a.configure(apiKey: "amp-key", deviceId: "dev-1", firstOpenEvent: nil)
		a.logEvent("both", properties: ["long": text(143), "flag": true])
		let amplitudeProps = Amplitude.trackedEvents.last?.properties
		check((amplitudeProps?["long"] as? String)?.count == 143 && (amplitudeProps?["flag"] as? Bool) == true,
		      "AN-02 r6: Amplitude must get the original untouched — got \(String(describing: amplitudeProps))")
		check((firebaseParams("both")?["long"] as? String)?.count == 100 && (firebaseParams("both")?["flag"] as? String) == "true",
		      "AN-02 r6: Firebase must get the sanitised copy — got \(String(describing: firebaseParams("both")))")

		// FA-02 r12 — an empty Amplitude key switches Amplitude off and NOT Firebase.
		reset()
		up()
		let off = AmplitudeAnalytics()
		off.configure(apiKey: "", deviceId: "dev-2", firstOpenEvent: nil)
		off.logEvent("still_mirrored", properties: nil)
		check(Amplitude.trackedEvents.isEmpty && Amplitude.initCount == 0, "FA-02 r12 setup: an empty key must leave Amplitude off")
		check(firebaseParams("still_mirrored") != nil, "FA-02 r12: with Amplitude off the event must still reach Firebase — got \(Analytics.loggedEvents.map(\.name))")

		// …and Firebase down does not touch Amplitude (the other direction of invariant 6).
		reset()
		let amplitudeOnly = AmplitudeAnalytics()
		amplitudeOnly.configure(apiKey: "amp-key", deviceId: "dev-3", firstOpenEvent: nil)
		amplitudeOnly.logEvent("amplitude_only", properties: nil)
		check(Amplitude.trackedEvents.map(\.eventType) == ["amplitude_only"], "FA invariant 6: Firebase being down must not stop Amplitude — got \(Amplitude.trackedEvents.map(\.eventType))")
		check(Analytics.loggedEvents.isEmpty, "FA invariant 6: nothing may reach a Firebase that is not up")

		// AN-01 r12 / FA-03 r7 — the start pair reaches Firebase even with an empty Amplitude key, and
		// BEFORE the first event.
		reset()
		up()
		let start = AmplitudeAnalytics()
		start.configure(apiKey: "", deviceId: "dev-4", firstOpenEvent: nil)
		check(Analytics.userIDs == ["dev-4"], "AN-01 r12: the user id must reach Firebase even with an empty Amplitude key — got \(Analytics.userIDs)")
		check(Analytics.userProperties.contains { $0.name == "environment" && $0.value == "unknown" },
		      "AN-01 r12: `environment` must reach Firebase even with an empty Amplitude key — got \(Analytics.userProperties)")

		reset()
		up()
		let debug = AmplitudeAnalytics(isDebug: true)
		debug.configure(apiKey: "amp-key", deviceId: "dev-5", firstOpenEvent: "app_first_open")
		check(Analytics.userProperties.contains { $0.name == "environment" && $0.value == "debug" },
		      "AN-01 r12: a debug build says `debug` in Firebase too — got \(Analytics.userProperties)")
		let order = Analytics.callOrder
		let idIndex = order.firstIndex(of: "setUserID")
		let eventIndex = order.firstIndex(of: "logEvent:app_first_open")
		check(idIndex != nil && eventIndex != nil && idIndex! < eventIndex!,
		      "FA-03 r7: the user id must land in Firebase before the first event — order \(order)")
		check(eventIndex != nil, "AN-01: the first-open event is an event like any other and must be mirrored — got \(order)")

		// A test run: `configure` returns before everything, and Firebase hears nothing (the root never
		// builds this class in a test run, but the class itself must hold the same line).
		reset()
		up()
		let test = AmplitudeAnalytics()
		test.configure(apiKey: "amp-key", deviceId: "dev-6", firstOpenEvent: "app_first_open", isTestsRunning: true)
		check(Analytics.callOrder.isEmpty, "TM-07 r10: a test run must leave Firebase untouched — got \(Analytics.callOrder)")

		// AN-03 r7 — the public setters mirror too; FA-01 r5 — the ATT answer is not forwarded.
		reset()
		up()
		let live = AmplitudeAnalytics()
		live.configure(apiKey: "amp-key", deviceId: "dev-7", firstOpenEvent: nil)
		let before = Analytics.callOrder
		live.setUserId("dev-7b")
		live.setUserProperties(["status": "organic"])
		check(Analytics.userIDs.last == "dev-7b" && Analytics.userProperties.last?.name == "status" && Analytics.userProperties.last?.value == "organic",
		      "AN-03 r7: setUserId and setUserProperties must reach Firebase too — got \(Analytics.userIDs), \(Analytics.userProperties)")
		check(Amplitude.lastUserId == "dev-7b" && Amplitude.identifyCalls.last?["status"] as? String == "organic",
		      "AN-03 r7: …and Amplitude as before — got \(String(describing: Amplitude.lastUserId))")
		let afterSetters = Analytics.callOrder
		live.updateTrackingAuthorization(.authorized)
		check(Analytics.callOrder == afterSetters && afterSetters.count > before.count,
		      "FA-01 r5: the ATT answer must not be forwarded to Firebase — it reads the status itself; calls \(afterSetters) → \(Analytics.callOrder)")
	}
}
