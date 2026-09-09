//
//  AmplitudeAnalyticsCheck.swift
//  IntegrationKit
//
//  Written from the approved schemas AN-01..AN-04, not from the code. Fifteen of the twenty-six
//  rows across the four risk tables are testable with the `AmplitudeSwift` stub (plus real
//  `AppTrackingTransparency` enum literals for the two ATT-parameter rows); three more are carried
//  by `AppsFlyerServiceCheck.swift` and `AdaptyServiceCheck.swift`, because the code they name
//  lives there; the remaining eight say why in the comment above them rather than being closed by
//  a lookalike assert.
//
//  T14..T17 were added on `b6ac9ef`, after the schemas were re-read against the decisions taken
//  since they were written. They are appended at the end on purpose: renumbering would move every
//  assert coordinate already quoted in the four risk tables. T14 and T15 pin the shared logging
//  decision of 2026-09-09 (`[IntegrationKit][<tag>]`, `info`/`error`, the data rather than the
//  fact of the call) on the two places that already obey it; T16 and T17 pin the two outputs the
//  schemas described less precisely than the code produces them — a configured layer whose device
//  id is still nil, and a `configure()` that attaches the IDFA plugin without being told the ATT
//  status.
//
//  All of them are green as of `60169db`. T1, T2, T10, T11, T12, T13 were written red first, as the
//  spec for behaviour the wrapper did not have: the first-open gate closes only after the event
//  ships, not before it (AN-01 row 1); a configure() that finally names the event still sends it
//  after an earlier unnamed call (AN-01 row 2); a second `.authorized` call does not add a second
//  IDFA plugin (AN-04 row 1); an `.authorized` call that arrives before configure() still takes
//  effect once configure() runs (AN-04 row 2); a missing App Store receipt reads as "unknown"
//  rather than as a production install (AN-01 row 4); and an inactive layer names the reason it is
//  inactive (AN-01 row 3). T3, T4, T5, T6, T7, T8, T9 were green from the start and pin exactly
//  what the contract already got right, so a later change cannot loosen it silently — including
//  AN-01 row 6, whose own
//  reproduction step only asks to confirm the SDK reinitialises on a second configure() (one of
//  the two contract-legal outcomes for that row), not to demand a guard that does not exist.
//
//  Eight rows are NOT covered here, for four distinct reasons:
//   - AN-01 row 7 and AN-03 row 5 are read-by-code per their own "Як відтворити": no assert invents
//     what the schema itself says to verify by reading.
//   - AN-04 rows 3-5 need a real `ATTrackingManager`/`ASIdentifierManager` read this process cannot
//     force (confirmed empirically to always answer `.notDetermined` outside an app bundle), so the
//     `.authorized` branch they live in never fires here.
//   - AN-02 row 1 is a pure pointer to AN-01 row 3 (asserted once, by T13), and AN-03 row 2 is the
//     Adapty side of the same missing device id — it belongs to `AdaptyServiceCheck.swift` (T02,
//     AD-01 row 2), which already compiles `AdaptyService`.
//   - AN-03 row 6 and AN-04 row 6 name log lines `AmplitudeAnalytics` does not write yet (Asana
//     1218282418284338). The assert exists in shape — install a `debugLogSink`, call the operation,
//     read the line back, exactly as T14 and T15 do — but it would be red, and this phase does not
//     touch `Sources/`. The rows carry that reason instead of a lookalike.
//  AN-02 row 4 and AN-03 row 4 name `AppsFlyerService.swift` and are asserted in
//  `AppsFlyerServiceCheck.swift` (the `af_` event names, and the unprefixed profile properties).
//
//  This check does not stop at the first failing row: every row runs, every failure is collected,
//  and the summary at the end reports all of them with a non-zero exit code — same shape as
//  `CrashlyticsCheck`. A non-zero exit is now a regression, not the expected outcome.
//  Run:  ./Checks/amplitude-analytics-check.sh
//

import AmplitudeSwift
import AppTrackingTransparency
import Foundation

@main
enum AmplitudeAnalyticsCheck {
	static var failures: [String] = []

	/// `AmplitudeAnalytics` writes this UserDefaults flag exactly once per install
	/// (`AmplitudeAnalytics.swift:12`). Cleared at the start of every row that touches first-open,
	/// or one row's gate leaks into the next and goes green for the wrong reason.
	static let firstOpenTrackedKey = "IntegrationKit.amplitude.firstOpenTracked"

	/// Records a failure instead of trapping — one failing row must not stop every row after it
	/// from running.
	static func check(_ condition: @autoclosure () -> Bool, _ message: @autoclosure () -> String) {
		guard !condition() else { return }
		let text = message()
		failures.append(text)
		print("FAILED: \(text)")
	}

	static func main() {
		// ── AN-01 row 1 — the first-open gate must not close before the event ships ────────
		// Executes `AmplitudeAnalytics.swift:77-100`. Green: `:95` hands the event over and only
		// then `:99` writes the flag — the flag used to be written first, so at the instant it
		// became true no event had shipped yet. `UserDefaults`
		// posts `didChangeNotification` synchronously right after `set()` (confirmed empirically),
		// which is the only way to catch that instant without touching `Sources/`.
		UserDefaults.standard.removeObject(forKey: firstOpenTrackedKey)
		Amplitude.reset()
		var trackedCountWhenFlagWritten: Int?
		let row1Observer = NotificationCenter.default.addObserver(
			forName: UserDefaults.didChangeNotification, object: UserDefaults.standard, queue: nil
		) { _ in
			if trackedCountWhenFlagWritten == nil, UserDefaults.standard.bool(forKey: firstOpenTrackedKey) {
				trackedCountWhenFlagWritten = Amplitude.trackedEvents.count
			}
		}
		let row1 = AmplitudeAnalytics()
		row1.configure(apiKey: "amp-key", deviceId: "device-1", firstOpenEvent: "first_open")
		NotificationCenter.default.removeObserver(row1Observer)
		check(
			(trackedCountWhenFlagWritten ?? 0) > 0,
			"T1 AN-01 row 1: the first-open event must already be tracked when the gate flag is "
				+ "written, got \(trackedCountWhenFlagWritten.map(String.init) ?? "flag never written") "
				+ "tracked event(s) at that instant"
		)

		// ── AN-01 row 2 — an unnamed first-open must not burn the gate for a later named one ──
		// Executes `AmplitudeAnalytics.swift:94` (nothing to send is nothing to close) and `:95-99`
		// (send, then close). Green: the unnamed first call returns before the gate, so the second
		// `configure()` still has it to spend. It used to close unconditionally.
		UserDefaults.standard.removeObject(forKey: firstOpenTrackedKey)
		Amplitude.reset()
		let row2First = AmplitudeAnalytics()
		row2First.configure(apiKey: "amp-key-1", deviceId: "device-2a", firstOpenEvent: nil)
		let row2Second = AmplitudeAnalytics()
		row2Second.configure(apiKey: "amp-key-2", deviceId: "device-2b", firstOpenEvent: "first_open")
		check(
			Amplitude.trackedEvents.contains { $0.eventType == "first_open" },
			"T2 AN-01 row 2: a later configure() that finally names the first-open event must still "
				+ "send it, got \(Amplitude.trackedEvents.map { $0.eventType })"
		)

		// ── AN-01 row 3 — an inactive layer must say which of the two reasons it is ────────
		// Executes the empty-key guard in `AmplitudeAnalytics.configure`. The row asks for the
		// cause, not the fact: an empty key and a test run are cured differently, so "analytics is
		// off" alone is useless to whoever reads it. Only the empty-key half is asserted — the
		// test-run branch has no code yet (decision 2026-09-08, task 1218288104081038), and an
		// assert for a branch that cannot be reached would be a lookalike. The "stays inactive"
		// half is AN-01 row 8's, further down. Green since `:30-36` records the cause.
		UserDefaults.standard.removeObject(forKey: firstOpenTrackedKey)
		Amplitude.reset()
		ConfigurationIssues.shared.reset()
		let row3 = AmplitudeAnalytics()
		row3.configure(apiKey: "", deviceId: "device-3", firstOpenEvent: "first_open")
		check(
			ConfigurationIssues.shared.all.contains { $0.contains("API key") },
			"T13 AN-01 row 3: an empty Amplitude key must record the cause, got "
				+ "\(ConfigurationIssues.shared.all)"
		)
		check(
			Amplitude.initCount == 0,
			"T13 AN-01 row 3: an empty key must not stand the SDK up, got "
				+ "\(Amplitude.initCount) initialization(s)"
		)

		// ── AN-01 row 4 — a missing receipt is "unknown", not a production install ────────
		// Executes `AmplitudeAnalytics.swift:83-89`. The schema's own "Як відтворити" calls this
		// row read-by-code, because `Bundle.main.appStoreReceiptURL` looks the same on every run
		// here. It does — and that constant is exactly what made the row testable: this process has
		// no App Store receipt, and the old two-way branch called that production. Green: `:87` is
		// the third value the row asked for. What stays out of reach is only the sandbox half, and
		// no assert below claims it.
		UserDefaults.standard.removeObject(forKey: firstOpenTrackedKey)
		Amplitude.reset()
		let row4 = AmplitudeAnalytics()
		row4.configure(apiKey: "amp-key", deviceId: "device-4", firstOpenEvent: "first_open")
		check(
			Amplitude.identifyCalls.first?["environment"] as? String == "unknown",
			"T12 AN-01 row 4: with no App Store receipt the environment must read \"unknown\", got "
				+ "\(String(describing: Amplitude.identifyCalls.first?["environment"]))"
		)

		// ── AN-01 row 5 — user id must be set before the first event ships ─────────────────
		// Executes `AmplitudeAnalytics.swift:39` (setUserId) ahead of `:44` (trackFirstOpenOnce).
		// Green, already correct: `userIdAtFirstTrack` snapshots `lastUserId` the moment `track`
		// first runs, so this proves the order rather than just the end state — both calls having
		// happened does not, by itself, say which ran first.
		UserDefaults.standard.removeObject(forKey: firstOpenTrackedKey)
		Amplitude.reset()
		let row5 = AmplitudeAnalytics()
		row5.configure(apiKey: "amp-key", deviceId: "device-5", firstOpenEvent: "first_open")
		check(
			Amplitude.userIdAtFirstTrack == "device-5",
			"T3 AN-01 row 5: setUserId must run before the first tracked event, got "
				+ "\(String(describing: Amplitude.userIdAtFirstTrack))"
		)

		// ── AN-01 row 6 — a second configure() is a full replacement, not a crash or a merge ──
		// Executes `AmplitudeAnalytics.swift:37` twice. Green as written: the row's own "Як
		// відтворити" only asks to confirm the SDK reinitialises — one of the two contract-legal
		// outcomes ("no-op, or full replacement without loss") — not to demand the guard `:37`
		// does not have.
		Amplitude.reset()
		let row6 = AmplitudeAnalytics()
		row6.configure(apiKey: "amp-key-a", deviceId: "device-6a", firstOpenEvent: nil)
		row6.configure(apiKey: "amp-key-b", deviceId: "device-6b", firstOpenEvent: nil)
		check(
			Amplitude.initCount == 2,
			"T4 AN-01 row 6: two configure() calls on one instance must reach the SDK as two "
				+ "initialisations (full replacement), got \(Amplitude.initCount)"
		)

		// AN-01 row 7 is NOT covered: its own "Як відтворити" calls this read-by-code — verified
		// by reading the composition root (`IntegrationKit.swift:66-67`), not by exercising it here.

		// ── AN-01 row 8 — an inactive layer must not burn the first-open gate ──────────────
		// Executes `AmplitudeAnalytics.swift:30-36` (early return before the gate is ever touched).
		// Green already: kept as a guard against `:30-44`'s order being reshuffled by accident —
		// an empty-key run must not spend the one-time gate on an open analytics never saw.
		UserDefaults.standard.removeObject(forKey: firstOpenTrackedKey)
		Amplitude.reset()
		let row8Inactive = AmplitudeAnalytics()
		row8Inactive.configure(apiKey: "", deviceId: "device-8", firstOpenEvent: "first_open")
		let gateUntouchedByInactiveLayer = UserDefaults.standard.object(forKey: firstOpenTrackedKey) == nil
		let row8Real = AmplitudeAnalytics()
		row8Real.configure(apiKey: "amp-key", deviceId: "device-8", firstOpenEvent: "first_open")
		check(
			gateUntouchedByInactiveLayer && Amplitude.trackedEvents.contains { $0.eventType == "first_open" },
			"T5 AN-01 row 8: an inactive (empty-key) configure() must leave the first-open gate "
				+ "untouched (untouched=\(gateUntouchedByInactiveLayer)) so a later real configure() "
				+ "still sends it, got trackedEvents=\(Amplitude.trackedEvents.map { $0.eventType })"
		)

		// AN-02 row 1 carries no assert of its own: its own text is a pointer to AN-01 row 3, and
		// that row is asserted once, by T13 above. Asserting it twice would hide which one owns it.

		// ── AN-02 setup — one configured instance, reused by rows 2 and 3 ──────────────────
		UserDefaults.standard.removeObject(forKey: firstOpenTrackedKey)
		Amplitude.reset()
		let an02 = AmplitudeAnalytics()
		an02.configure(apiKey: "amp-key", deviceId: "device-an02", firstOpenEvent: nil)

		// ── AN-02 row 2 — properties reach the SDK exactly as given, non-serialisable types too ──
		// Executes `AmplitudeAnalytics.swift:55-58`. Green: `properties` is forwarded to `track`
		// with no conversion or filtering — the contract's deliberate choice, pinned so a
		// "helpful" sanitiser does not creep in later.
		Amplitude.reset()
		let signupDate = Date(timeIntervalSince1970: 0)
		an02.logEvent("subscription_started", properties: ["signed_up_at": signupDate, "plan": "pro"])
		let loggedRow2 = Amplitude.trackedEvents.first
		check(
			loggedRow2?.eventType == "subscription_started"
				&& (loggedRow2?.properties?["signed_up_at"] as? Date) == signupDate
				&& (loggedRow2?.properties?["plan"] as? String) == "pro",
			"T6 AN-02 row 2: properties (including a non-serialisable Date) must reach the SDK "
				+ "unchanged, got \(String(describing: loggedRow2?.properties))"
		)

		// ── AN-02 row 3 — a background-thread call must not crash or get dropped ───────────
		// Executes `AmplitudeAnalytics.swift:55-58` from two queues at once. Green: `track` is
		// documented thread-safe by Amplitude itself, so the wrapper adds no hop of its own — this
		// proves the claim instead of leaving it as an assurance, same idea as `CrashlyticsCheck`'s
		// T7. The stub's own array is not thread-safe, so the two calls are serialised through one
		// queue after being dispatched from two — what is under test is the wrapper, not the stub.
		Amplitude.reset()
		let row3Group = DispatchGroup()
		let row3Serial = DispatchQueue(label: "amplitude-check.an02.row3")
		for index in 0..<2 {
			DispatchQueue.global().async(group: row3Group) {
				row3Serial.sync {
					an02.logEvent("bg_event_\(index)")
				}
			}
		}
		let row3Finished = row3Group.wait(timeout: .now() + 2) == .success
		check(
			row3Finished && Amplitude.trackedEvents.count == 2,
			"T7 AN-02 row 3: two logEvent calls from different queues must both reach the SDK, "
				+ "finished=\(row3Finished), got \(Amplitude.trackedEvents.count)"
		)

		// AN-02 row 4 is NOT covered: the two event names it checks (`af_onConversionData`,
		// `af_didResolveDeepLink`) are sent from `AppsFlyerService.swift`, not from this wrapper.
		// Wiring `AppsFlyerService` in pulls its whole dependency tree (`AppsFlyerServicing`,
		// `AdaptyServicing`, UIKit, the AppsFlyerLib stubs) into a check scoped to three Amplitude
		// files — not practical here, same reasoning as AN-03 row 2 for `AdaptyService`.

		// ── AN-03 row 1 — deviceId before configure() answers nil, not a crash ─────────────
		// Executes `AmplitudeAnalytics.swift:51-53`. Green: `amplitude` is nil until `configure()`
		// runs, and the optional chain answers nil instead of trapping.
		let row1An03 = AmplitudeAnalytics()
		check(
			row1An03.deviceId == nil,
			"T8 AN-03 row 1: deviceId read before configure() must answer nil, got "
				+ "\(String(describing: row1An03.deviceId))"
		)

		// AN-03 row 2 is covered elsewhere, on purpose: it is the Adapty side of this same missing
		// device id (`AdaptyService.linkAmplitudeUserId`), and it is asserted by
		// `AdaptyServiceCheck.swift` T02 (AD-01 row 2) — the `?? ""` is gone, the field is left
		// unset and the reason is recorded. Wiring `AdaptyService` into this check would pull in
		// `AdaptyServicing`/`AdaptyPremiumProviding`, `AdaptyPurchaseResult`, `SingleResume`,
		// `PremiumProduct` and the full `Adapty` SDK stub — not practical for a check scoped to
		// three Amplitude files.

		// ── AN-03 row 3 — an explicit setUserId overrides the configure()-time id, as designed ──
		// Executes `AmplitudeAnalytics.swift:47-49`. Green, deliberately: the method does not
		// validate its input — the boundary the row exists to record, not a defect.
		UserDefaults.standard.removeObject(forKey: firstOpenTrackedKey)
		Amplitude.reset()
		let row3An03 = AmplitudeAnalytics()
		row3An03.configure(apiKey: "amp-key", deviceId: "device-3", firstOpenEvent: nil)
		row3An03.setUserId("other-user")
		check(
			Amplitude.lastUserId == "other-user",
			"T9 AN-03 row 3: setUserId with an id different from configure()'s must reach the SDK "
				+ "exactly as given, got \(String(describing: Amplitude.lastUserId))"
		)

		// AN-03 row 4 is NOT covered here: it exercises `AppsFlyerService.swift:139-143` (the
		// `af_`-prefixed profile properties, unprefixed until 2026-09-09), not this wrapper — same
		// out-of-scope reasoning as AN-02 row 4. `AppsFlyerServiceCheck.swift` T24 owns it.

		// AN-03 row 5 is NOT covered: its own "Як відтворити" calls this read-by-code — the
		// `AmplitudeSwift` stub's `identify` has no delete/remove counterpart to call.

		// ── AN-04 row 1 — a second `.authorized` call must not add a second plugin ─────────
		// Executes `AmplitudeAnalytics.swift:67-69` twice, both times through `addIDFAPluginOnce`
		// (`:71-75`). Green: the flag at `:22` holds the count at one. The SDK's own dedup cannot —
		// it keys on `plugin.name`, whose witness is statically `nil` on this pin.
		UserDefaults.standard.removeObject(forKey: firstOpenTrackedKey)
		Amplitude.reset()
		let row1An04 = AmplitudeAnalytics()
		row1An04.configure(apiKey: "amp-key", deviceId: "device-an04a", firstOpenEvent: nil)
		row1An04.updateTrackingAuthorization(.authorized)
		row1An04.updateTrackingAuthorization(.authorized)
		check(
			Amplitude.addedPluginCount == 1,
			"T10 AN-04 row 1: two `.authorized` calls must add the IDFA plugin once, got "
				+ "\(Amplitude.addedPluginCount)"
		)

		// ── AN-04 row 2 — an `.authorized` call before configure() must not be lost ────────
		// Executes `AmplitudeAnalytics.swift:68` while `amplitude` is still nil, so that call is
		// dropped — and it no longer matters: `:43` attaches the plugin during `configure()`
		// unconditionally, and the plugin re-reads the ATT status on every event. Green.
		UserDefaults.standard.removeObject(forKey: firstOpenTrackedKey)
		Amplitude.reset()
		let row2An04 = AmplitudeAnalytics()
		row2An04.updateTrackingAuthorization(.authorized)
		row2An04.configure(apiKey: "amp-key", deviceId: "device-an04b", firstOpenEvent: nil)
		check(
			Amplitude.addedPluginCount == 1,
			"T11 AN-04 row 2: an `.authorized` call received before configure() must still add "
				+ "the IDFA plugin once configure() runs, got \(Amplitude.addedPluginCount)"
		)

		// AN-04 row 3 is NOT covered: `AmplitudeIDFAPlugin.swift:14` reads the real
		// `ATTrackingManager.trackingAuthorizationStatus`, not a parameter — confirmed empirically
		// to always answer `.notDetermined` in a plain command-line process (no app bundle/TCC
		// identity), so the `.authorized` branch this row is about can never execute here. Its own
		// "Як відтворити" calls this the same limitation.

		// AN-04 row 4 is NOT covered: same system read as row 3, this time gating
		// `ASIdentifierManager.shared().advertisingIdentifier` at `AmplitudeIDFAPlugin.swift:15`
		// — its own "Як відтворити" says so directly.

		// AN-04 row 5 is NOT covered: the field write it is about (`AmplitudeIDFAPlugin.swift:15`)
		// lives inside the same `.authorized` branch as rows 3-4, which this process cannot reach.
		// A pass-through run (status always `.notDetermined` here) would touch no field at all and
		// would not be evidence that only `idfa` changes when the branch does fire — that would be
		// a lookalike assert, not coverage.

		// ── AN-01 row 9 — the one trace this layer does emit carries prefix, tag and level ──
		// Executes `ConfigurationIssues.record` (`ConfigurationIssues.swift:42-53`) into `debugLog`
		// (`DebugLog.swift:20-39`). Pins the shared logging decision of 2026-09-09 —
		// `[IntegrationKit][<service>]`, `info`/`error`, DEBUG-only — on the half of AN-01 row 9 the
		// code already has. `debugLogSink` is the only readable destination: this check builds
		// without `-D DEBUG`, so `DebugLog.swift:25-27` is the branch that runs. The other three
		// obligations of that row (which deviceId went in, whether the gate let the event through)
		// have no code at all and therefore no assert — see the row.
		UserDefaults.standard.removeObject(forKey: firstOpenTrackedKey)
		Amplitude.reset()
		ConfigurationIssues.shared.reset()
		var row9Lines: [String] = []
		debugLogSink = { row9Lines.append($0) }
		let row9 = AmplitudeAnalytics()
		row9.configure(apiKey: "", deviceId: "device-9", firstOpenEvent: "first_open")
		debugLogSink = nil
		check(
			row9Lines.contains {
				$0.hasPrefix("[IntegrationKit][AmplitudeAnalytics][error] ") && $0.contains("empty API key")
			},
			"T14 AN-01 row 9: the empty-key cause must reach the log as "
				+ "\"[IntegrationKit][AmplitudeAnalytics][error] …empty API key…\", got \(row9Lines)"
		)

		// ── AN-02 row 5 — logEvent logs the data, not the fact of the call ────────────────
		// Executes `AmplitudeAnalytics.swift:56`. The 2026-09-09 decision asks for the event name
		// *and the whole properties dictionary* at `info`, under the package prefix and the service
		// tag. This is the only operation of the four cases that already obeys it, so this is where
		// the format itself gets pinned — a tag folded back into the message string, or a drop back
		// to "logged an event", fails here.
		Amplitude.reset()
		var row5Lines: [String] = []
		debugLogSink = { row5Lines.append($0) }
		an02.logEvent("paywall_shown", properties: ["placement": "onboarding"])
		debugLogSink = nil
		check(
			row5Lines.contains {
				$0.hasPrefix("[IntegrationKit][AmplitudeAnalytics] ")
					&& !$0.contains("[error]")
					&& $0.contains("paywall_shown")
					&& $0.contains("placement")
					&& $0.contains("onboarding")
			},
			"T15 AN-02 row 5: logEvent must log the event name and the whole properties dictionary "
				+ "at info level under \"[IntegrationKit][AmplitudeAnalytics]\", got \(row5Lines)"
		)

		// ── AN-03 row 1 — an active layer may still answer nil, and must not fake a value ──
		// Executes `AmplitudeAnalytics.swift:51-53` with the SDK holding no id. The schema used to
		// read "active → the Amplitude device id", which is the state the wrapper cannot promise:
		// `getDeviceId()` is optional at every moment of the layer's life, not only before
		// `configure()`. T8 covers the pre-configure half; this one covers the half AN-03 row 2 is
		// actually about, on the Amplitude side of that pair.
		UserDefaults.standard.removeObject(forKey: firstOpenTrackedKey)
		Amplitude.reset()
		let row1NilId = AmplitudeAnalytics()
		row1NilId.configure(apiKey: "amp-key", deviceId: "device-an03-nil", firstOpenEvent: nil)
		Amplitude.deviceId = nil
		check(
			row1NilId.deviceId == nil,
			"T16 AN-03 row 1: a configured layer whose SDK has no device id yet must still answer "
				+ "nil, never a stand-in value, got \(String(describing: row1NilId.deviceId))"
		)

		// ── AN-04 row 2 — configure() attaches the plugin without being told the ATT status ──
		// Executes `AmplitudeAnalytics.swift:43` with no `updateTrackingAuthorization` call at all.
		// T11 proves an early `.authorized` is not lost; it cannot prove the attach is
		// unconditional, because in T11 the app did answer. This one removes the answer entirely —
		// the shape the third option of AN-04 row 2 was chosen for, and the shape the AN-04
		// flowchart's old `дозволено?` gate denied.
		UserDefaults.standard.removeObject(forKey: firstOpenTrackedKey)
		Amplitude.reset()
		let row2Unconditional = AmplitudeAnalytics()
		row2Unconditional.configure(apiKey: "amp-key", deviceId: "device-an04c", firstOpenEvent: nil)
		check(
			Amplitude.addedPluginCount == 1,
			"T17 AN-04 row 2: configure() must attach the IDFA plugin without being told the ATT "
				+ "status, got \(Amplitude.addedPluginCount)"
		)

		if failures.isEmpty {
			print("AmplitudeAnalytics (AN-01..AN-04): 18/18 OK")
		} else {
			print("\(failures.count) of 18 asserts FAILED")
			exit(1)
		}
	}
}
