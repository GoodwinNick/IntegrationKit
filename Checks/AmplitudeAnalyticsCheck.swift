//
//  AmplitudeAnalyticsCheck.swift
//  IntegrationKit
//
//  Written from the approved schemas AN-01..AN-04, not from the code. Twelve rows across the four
//  risk tables are testable with the `AmplitudeSwift` stub (plus real `AppTrackingTransparency`
//  enum literals for the two ATT-parameter rows); two more are carried by
//  `AppsFlyerServiceCheck.swift`, because the code they name lives there; the remaining eight say
//  why in the comment above them rather than being closed by a lookalike assert.
//
//  T1, T2, T10, T11, T12 are red on purpose — they are the spec for behaviour the wrapper does not have
//  yet: the first-open gate must close only after the event ships, not before it (AN-01 row 1); a
//  configure() that finally names the event must still send it even after an earlier unnamed call
//  (AN-01 row 2); a second `.authorized` call must not add a second IDFA plugin (AN-04 row 1); and
//  an `.authorized` call that arrives before configure() must still take effect once configure()
//  runs (AN-04 row 2); and a missing App Store receipt must read as "unknown" rather than as a
//  production install (AN-01 row 4). T3, T4, T5, T6, T7, T8, T9 are green and pin exactly what the contract
//  already gets right, so a later change cannot loosen it silently — including AN-01 row 6, whose
//  own reproduction step only asks to confirm the SDK reinitialises on a second configure() (one of
//  the two contract-legal outcomes for that row), not to demand a guard that does not exist.
//
//  Eight rows are NOT covered here, for three distinct reasons:
//   - AN-01 rows 3 and 7, and AN-03 row 5, are read-by-code per their own "Як відтворити": no
//     assert invents what the schema itself says to verify by reading. AN-01 row 3 also has no
//     readable channel — its trace goes through `debugLog` to stdout.
//   - AN-04 rows 3-5 need a real `ATTrackingManager`/`ASIdentifierManager` read this process cannot
//     force (confirmed empirically to always answer `.notDetermined` outside an app bundle), so the
//     `.authorized` branch they live in never fires here.
//   - AN-02 row 1 is a pure pointer to AN-01 row 3, and AN-03 row 2 names `AdaptyService.swift:232`
//     — that line belongs to `AdaptyServiceCheck.swift`, which already compiles `AdaptyService`.
//  AN-02 row 4 and AN-03 row 4 name `AppsFlyerService.swift` and are asserted in
//  `AppsFlyerServiceCheck.swift` (the `af_` event names, and the unprefixed profile properties).
//
//  This check does not stop at the first failing row: every row runs, every failure is collected,
//  and the summary at the end reports all of them with a non-zero exit code — same shape as
//  `CrashlyticsCheck`. A non-zero exit here is the expected, healthy outcome until AN-01 rows 1-2
//  and AN-04 rows 1-2 are implemented.
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
		// Executes `AmplitudeAnalytics.swift:50-56`. Red: `:51` writes the flag, then `:53-56`
		// send — so at the instant the flag becomes true, no event has shipped yet. `UserDefaults`
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
		// Executes `AmplitudeAnalytics.swift:50-51` (closes unconditionally) and `:54-56` (sends
		// only if named). Red: the second `configure()` never sends, because the first already
		// closed the gate with nothing to send.
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

		// AN-01 row 3 is NOT covered: the spec asks for one trace in the logs naming why the layer
		// stayed inactive. `debugLog` only ever calls `print`, which this check has no way to read
		// — same limitation as `CrashlyticsCheck`'s CR-01 row 1. The test-run half of the row has
		// no branch in the code yet either (decision 2026-09-08, task 1218288104081038), so there
		// is nothing to route a setup at. The "stays inactive" half is not in question — AN-01
		// row 8 below already exercises that same guard from the state side.

		// ── AN-01 row 4 — a missing receipt is "unknown", not a production install ────────
		// Executes `AmplitudeAnalytics.swift:52-53`. The schema's own "Як відтворити" calls this
		// row read-by-code, because `Bundle.main.appStoreReceiptURL` looks the same on every run
		// here. It does — and that constant is exactly the row's defect rather than an obstacle to
		// it: this process has no App Store receipt, so `:52` takes the `!= "sandboxReceipt"`
		// branch and reports every install as production. RED: the row asks for a third value.
		// What stays out of reach is only the sandbox half, and no assert below claims it.
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
		// Executes `AmplitudeAnalytics.swift:22` (setUserId) ahead of `:23` (trackFirstOpenOnce).
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
		// Executes `AmplitudeAnalytics.swift:20` twice. Green as written: the row's own "Як
		// відтворити" only asks to confirm the SDK reinitialises — one of the two contract-legal
		// outcomes ("no-op, or full replacement without loss") — not to demand the guard `:20`
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
		// by reading the composition root (`IntegrationKit.swift:59-60`), not by exercising it here.

		// ── AN-01 row 8 — an inactive layer must not burn the first-open gate ──────────────
		// Executes `AmplitudeAnalytics.swift:19` (early return before the gate is ever touched).
		// Green already: kept as a guard against `:19-23`'s order being reshuffled by accident —
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

		// AN-02 row 1 is NOT covered: its own text is a pointer to AN-01 row 3, not a separate
		// test — asserting it again here would hide that AN-01 row 3 has no assert of its own.

		// ── AN-02 setup — one configured instance, reused by rows 2 and 3 ──────────────────
		UserDefaults.standard.removeObject(forKey: firstOpenTrackedKey)
		Amplitude.reset()
		let an02 = AmplitudeAnalytics()
		an02.configure(apiKey: "amp-key", deviceId: "device-an02", firstOpenEvent: nil)

		// ── AN-02 row 2 — properties reach the SDK exactly as given, non-serialisable types too ──
		// Executes `AmplitudeAnalytics.swift:34-37`. Green: `properties` is forwarded to `track`
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
		// Executes `AmplitudeAnalytics.swift:34-37` from two queues at once. Green: `track` is
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
		// Executes `AmplitudeAnalytics.swift:30-32`. Green: `amplitude` is nil until `configure()`
		// runs, and the optional chain answers nil instead of trapping.
		let row1An03 = AmplitudeAnalytics()
		check(
			row1An03.deviceId == nil,
			"T8 AN-03 row 1: deviceId read before configure() must answer nil, got "
				+ "\(String(describing: row1An03.deviceId))"
		)

		// AN-03 row 2 is NOT covered: it exercises `AdaptyService.swift:232`
		// (`analytics.deviceId ?? ""`), not this wrapper. Wiring `AdaptyService` into this check
		// pulls in `AdaptyServicing`/`AdaptyPremiumProviding`, `AdaptyPurchaseResult`,
		// `SingleResume`, `PremiumProduct`, and the full `Adapty` SDK stub — not practical for a
		// check scoped to three Amplitude files.

		// ── AN-03 row 3 — an explicit setUserId overrides the configure()-time id, as designed ──
		// Executes `AmplitudeAnalytics.swift:26-28`. Green, deliberately: the method does not
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

		// AN-03 row 4 is NOT covered: it exercises `AppsFlyerService.swift:84-88` (the
		// un-prefixed `status`/`media_source`/`campaign_name` profile properties), not this
		// wrapper — same out-of-scope reasoning as AN-02 row 4.

		// AN-03 row 5 is NOT covered: its own "Як відтворити" calls this read-by-code — the
		// `AmplitudeSwift` stub's `identify` has no delete/remove counterpart to call.

		// ── AN-04 row 1 — a second `.authorized` call must not add a second plugin ─────────
		// Executes `AmplitudeAnalytics.swift:44-46` twice. Red: there is neither a flag nor an
		// existence check, so the plugin count doubles instead of staying at one.
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
		// Executes `AmplitudeAnalytics.swift:45` while `amplitude` is still nil. Red: the status
		// is not remembered anywhere, so the optional chain silently drops the call and
		// configure() never replays it.
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

		if failures.isEmpty {
			print("AmplitudeAnalytics (AN-01..AN-04): 12/12 OK")
		} else {
			print("\(failures.count) of 12 rows FAILED")
			exit(1)
		}
	}
}
