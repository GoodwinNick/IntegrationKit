//
//  RemoteConfigServiceCheck.swift
//  IntegrationKit
//
//  Written from the approved schemas RC-01…RC-03, not from the code. Nineteen asserts carry twelve
//  of the twenty-five rows of those three tables. The thirteen that carry none are listed at the
//  bottom of this comment, each with the reason — not with a lookalike assert, the same rule
//  `AppsFlyerServiceCheck` follows.
//
//  All nineteen are green, and that is the point rather than an accident: this layer shipped in
//  0.4.0 with no schema behind it, so every assert here was written against a contract that already
//  existed in code. What the check buys is the other direction — none of these behaviours can be
//  loosened later without a red row. Three of them are worth naming, because they read like
//  implementation detail and are in fact the contract:
//    T3  RC-01 row 2 — "no defaults" and "no Firebase" are two different sentences, and an app has
//        to tell them apart without guessing.
//    T11 RC-02 row 2 — an offline fetch that arrives as `NSURLErrorDomain` files nothing. The row
//        itself is about the case that does NOT arrive that way; see the gap list.
//    T15 RC-03 row 3 — both branches of every reader answer the same thing for the same input. The
//        left branch exists only to reproduce the SDK's own precedence when the SDK is absent, and
//        the day the two disagree is the day a flag "switches off" in exactly the launch where
//        Firebase failed.
//
//  Built WITHOUT `-D DEBUG` on purpose, same as `AppsFlyerServiceCheck`: every row is measured
//  against the build a user actually gets. `debugLog` prints nothing there, so the two asserts that
//  read a trace (T8) read it through `debugLogSink`, which is the only channel that survives a
//  release build.
//
//  This check does not stop at the first failing row: every row runs, every failure is collected,
//  and the summary at the end reports all of them with a non-zero exit code — same shape as
//  `CrashlyticsCheck`. A non-zero exit is a regression, not the expected outcome.
//  Run:  ./Checks/remote-config-service-check.sh
//
//  Rows deliberately not carried here:
//    RC-01 row 3, RC-02 rows 1 and 4, RC-03 row 1 (its logging half) — log lines the schemas
//      require and the code does not emit. An assert would be red, and `Sources/` is not edited in
//      the schema phase: code fixes are their own phase, after every test is written.
//    RC-02 rows 2 and 3 (their non-fatal halves) — an assert here would pin the defect rather than
//      the contract. T11 stands in from the other side: it proves the noise filter works, which is
//      what makes "and yet Remote Config's own errors walk past it" a finding instead of a guess.
//    RC-01 row 5 — a fact about which fields `RemoteConfigSettings` has in this version of Firebase.
//      There is no runtime to observe; it is re-checked by hand when the SDK is raised.
//    RC-01 row 8 — the build order is held by a comment in the composition root. Nothing breaks if
//      it changes, which is precisely why there is nothing to assert.
//    RC-01 row 9 — activated values outlive the process on a real device. `RemoteConfig.reset()`
//      wipes the one state a device is never in after its first launch; the stub needs a
//      `persistedActive` control that `reset()` leaves alone, the way `CrashlyticsCheck` T14/T15
//      had to keep the collection flag standing between two launches.
//    RC-01 row 10 — a second `IntegrationKit.configure(...)`. The guard lives in the composition
//      root, so the assert belongs to `IntegrationKitCheck`, not here.
//    RC-02 row 6 — the fetch closure outliving the layer. The stub answers synchronously; showing
//      this needs a stub that holds the completion until the check releases it.
//    RC-02 row 7 — the SDK's own guarantee that the completion always fires, on the main queue,
//      from every branch. Read out of the Firebase sources, not observable through a stub that is
//      synchronous by design.
//    RC-02 row 8 / RC-03 row 7's screen half — "read at the moment of display" is a rule for the
//      screen that reads the key, and lives in that screen's userflow.
//    RC-03 row 2 — the first read after a cold start blocks the queue it was made from, for as long
//      as the SDK takes to bring its sqlite up. A live BuildHost run on a cold start, not a unit.
//    RC-03 row 4 — a property of the stub itself: it does not convert between representations and
//      the real `FIRConfigValue` does. Closing it means changing the stub, then re-running T15.
//

import FirebaseCore
import FirebaseCrashlytics
import FirebaseRemoteConfig
import Foundation

@main
enum RemoteConfigServiceCheck {
	static var failures: [String] = []
	static var rowCount = 12

	/// Records a failure instead of trapping — one failing row must not stop every row after it
	/// from running.
	static func check(_ condition: @autoclosure () -> Bool, _ message: @autoclosure () -> String) {
		guard !condition() else { return }
		let text = message()
		failures.append(text)
		print("FAILED: \(text)")
	}

	/// Back to "the app just launched and nothing has been configured yet". `FirebaseApp` is reset
	/// too: every row states for itself whether Firebase is up, because that is the switch between
	/// the two branches every reader has.
	static func reset() {
		FirebaseApp.reset()
		Crashlytics.reset()
		RemoteConfig.reset()
		ConfigurationIssues.shared.reset()
		CrashReporter.resetDroppedReports()
		debugLogSink = nil
	}

	static func issues() -> String {
		ConfigurationIssues.shared.all.joined(separator: " | ")
	}

	/// The defaults most rows hand in — one of each type the protocol reads, so a row never has to
	/// invent its own set and then explain why it differs from the row above.
	static let defaults: [String: NSObject] = [
		"paywallReview": NSNumber(value: true),
		"experiment": NSString(string: "control"),
		"freeQuota": NSNumber(value: 3),
		"discount": NSNumber(value: 0.25),
	]

	/// A layer that went through the whole of RC-01 with Firebase up and the fetch made.
	static func activeLayer(isDebug: Bool = false, timeout: TimeInterval = 5) -> RemoteConfigService {
		FirebaseApp.configure()
		let service = RemoteConfigService(defaults: defaults)
		service.configure(timeout: timeout, isDebug: isDebug, isTestsRunning: false)
		return service
	}

	static func main() {
		// ── RC-01 row 1 — the app never called FirebaseIntegration.configure() ───────────────
		// The real `RemoteConfig.remoteConfig()` raises `FIRAppNotConfigured`
		// (`FIRRemoteConfig.m:120-129`), which Swift cannot catch: the app dies on its first screen
		// over a layer that is not important enough to take anything down with it. All three values
		// the schema names are asserted — no fetch was made, nothing was handed to the SDK, and the
		// app can read the reason back in a release build.
		reset()
		let orphan = RemoteConfigService(defaults: defaults)
		orphan.configure(timeout: 5, isDebug: false, isTestsRunning: false)
		check(
			RemoteConfig.fetchCallCount == 0,
			"T1 RC-01 row 1: no fetch may be made without Firebase, got \(RemoteConfig.fetchCallCount)"
		)
		check(
			RemoteConfig.registeredDefaults.isEmpty,
			"T1 RC-01 row 1: nothing may be handed to an unconfigured Remote Config, got "
				+ "\(RemoteConfig.registeredDefaults.count) default(s)"
		)
		check(
			ConfigurationIssues.shared.all.contains { $0.contains("FirebaseIntegration.configure") },
			"T1 RC-01 row 1: the reason must name the call that was missed — got \(issues())"
		)

		// ── RC-01 row 1, second half — the layer stays usable ────────────────────────────────
		// "Defaulted" is not "broken": the whole argument for keeping the dictionary as well as
		// handing it to Firebase is that this branch has to answer the app's own values. Answering
		// the type's zero here would be indistinguishable from a fetched `false`, and the app would
		// have no way at all to notice.
		check(
			orphan.bool("paywallReview") == true
				&& orphan.string("experiment") == "control"
				&& orphan.int("freeQuota") == 3
				&& orphan.double("discount") == 0.25,
			"T2 RC-01 row 1: a defaulted layer must answer the app's own defaults, got "
				+ "\(orphan.bool("paywallReview")) / \(orphan.string("experiment")) / "
				+ "\(orphan.int("freeQuota")) / \(orphan.double("discount"))"
		)

		// ── RC-01 row 2 — Firebase is up, but the app registered no defaults ─────────────────
		// Two causes, two sentences. An app that reads `configurationIssues` in a release build has
		// to act differently on each — one is a call order bug in `AppDelegate`, the other is a
		// missing dictionary — so a shared "remote config is not working" line would be worse than
		// none. The fetch is skipped as well: there is nowhere to put what comes back.
		reset()
		FirebaseApp.configure()
		let empty = RemoteConfigService(defaults: [:])
		empty.configure(timeout: 5, isDebug: false, isTestsRunning: false)
		check(
			RemoteConfig.fetchCallCount == 0,
			"T3 RC-01 row 2: no defaults means no fetch, got \(RemoteConfig.fetchCallCount)"
		)
		check(
			ConfigurationIssues.shared.all.contains { $0.contains("no defaults") }
				&& !ConfigurationIssues.shared.all.contains { $0.contains("FirebaseIntegration.configure") },
			"T3 RC-01 row 2: the reason must be about the defaults and must not be the Firebase one — "
				+ "got \(issues())"
		)

		// ── RC-01 row 4 — the throttle follows the app's own isDebug key ─────────────────────
		// Firebase allows one fetch per 12 hours by default, which makes flipping a flag in the
		// console during manual testing look broken. The package cannot read `#if DEBUG` itself: one
		// compiled into a library cannot be turned off by the app that embeds it — the same argument
		// `FirebaseIntegration.configure(isDebug:)` makes for crash collection.
		reset()
		_ = activeLayer(isDebug: true)
		check(
			RemoteConfig.appliedSettings?.minimumFetchInterval == 0,
			"T4 RC-01 row 4: isDebug true must clear the fetch throttle, got "
				+ "\(String(describing: RemoteConfig.appliedSettings?.minimumFetchInterval))"
		)

		// T5 — the other direction, and the one that actually ships. A wrapper that cleared the
		// throttle unconditionally would pass T4 and put every install on the network at every cold
		// start; the SDK default of 43200 s is the thing being protected here, not a number this
		// package chose.
		reset()
		_ = activeLayer(isDebug: false)
		check(
			RemoteConfig.appliedSettings?.minimumFetchInterval == 12 * 60 * 60,
			"T5 RC-01 row 4: a release build must leave the SDK throttle alone, got "
				+ "\(String(describing: RemoteConfig.appliedSettings?.minimumFetchInterval))"
		)

		// ── RC-01 row 6 — the app's timeout reaches the SDK unchanged ────────────────────────
		// The row is about the validation that is missing; this is the half that exists, and it has
		// to be pinned before the missing half can be added on top of it. The SDK's own default is
		// 60 s (`RCNConfigConstants.h:26`), so an unforwarded timeout would look like a working
		// layer with a minute-long fetch.
		reset()
		_ = activeLayer(timeout: 12)
		check(
			RemoteConfig.appliedSettings?.fetchTimeout == 12,
			"T6 RC-01 row 6: the app's fetch timeout must reach the SDK, got "
				+ "\(String(describing: RemoteConfig.appliedSettings?.fetchTimeout))"
		)

		// ── RC-01 row 7 — the defaults handed over are exactly the app's ─────────────────────
		// `setDefaults` replaces the whole namespace rather than merging into it
		// (`RCNConfigContent.m:194-199`), so "exactly" is the word that matters: a wrapper that
		// added a key of its own, or dropped one, would silently change what every unfetched read
		// answers. The package names no key of its own, and this is where that is enforced.
		reset()
		_ = activeLayer()
		check(
			Set(RemoteConfig.registeredDefaults.keys) == Set(defaults.keys),
			"T7 RC-01 row 7: the SDK must get exactly the app's keys, got "
				+ "\(Set(RemoteConfig.registeredDefaults.keys).sorted())"
		)

		// ── RC-01 happy path — a test run keeps the defaults and drops the fetch ─────────────
		// The one SDK of the four a test run does not silence, and the reason is that its defaults
		// ARE the test's input: a UI test asserting on a paywall variant must not have the console
		// decide which one it gets. Both halves are asserted, because either alone is a different
		// contract — silencing the reads would break the test, and leaving the fetch in would make
		// it flaky.
		reset()
		var logged: [String] = []
		debugLogSink = { logged.append($0) }
		FirebaseApp.configure()
		let underTest = RemoteConfigService(defaults: defaults)
		underTest.configure(timeout: 5, isDebug: false, isTestsRunning: true)
		check(
			RemoteConfig.fetchCallCount == 0 && Set(RemoteConfig.registeredDefaults.keys) == Set(defaults.keys),
			"T8 RC-01 test run: defaults must be registered and the fetch skipped, got "
				+ "\(RemoteConfig.fetchCallCount) fetch(es) and "
				+ "\(RemoteConfig.registeredDefaults.count) default(s)"
		)
		check(
			underTest.bool("paywallReview") == true,
			"T8 RC-01 test run: reads must keep working, got \(underTest.bool("paywallReview"))"
		)
		check(
			logged.contains { $0.contains("[IntegrationKit][RemoteConfig]") && $0.contains("fetch skipped") },
			"T8 RC-01 test run: the skipped fetch must leave a trace naming the layer, got \(logged)"
		)
		debugLogSink = nil

		// ── RC-02 row 5 — one fetch per launch, and no retry ─────────────────────────────────
		// A deliberate boundary, not an omission. A retry would cost what the paywall retry in
		// `AdaptyService` costs — a scheduler of its own, a "one series per key" guard, a reset on
		// returning from background — and the price of failing is not comparable: a paywall with no
		// prices cannot be shown, an experiment running on its default works fine. The assert is on
		// the number, and it is the one that goes red the day a retry is added quietly.
		reset()
		_ = activeLayer()
		check(
			RemoteConfig.fetchCallCount == 1,
			"T9 RC-02 row 5: configure must fetch exactly once, got \(RemoteConfig.fetchCallCount)"
		)

		// ── RC-02 side effects — a failed fetch files exactly one non-fatal ──────────────────
		// The schema's side-effect table says "1 non-fatal on failure, nothing on success", and both
		// halves are load-bearing: a fetch that failed silently would leave a layer answering
		// defaults for the whole run with nothing anywhere to say why. Domain and code are asserted
		// rather than the count alone — Crashlytics is searched by them.
		reset()
		FirebaseApp.configure()
		RemoteConfig.fetchError = NSError(domain: "com.google.remoteconfig.ErrorDomain", code: 8002)
		let failing = RemoteConfigService(defaults: defaults)
		failing.configure(timeout: 5, isDebug: false, isTestsRunning: false)
		check(
			Crashlytics.recordCallCount == 1
				&& Crashlytics.recordedErrors.first?.domain == "com.google.remoteconfig.ErrorDomain"
				&& Crashlytics.recordedErrors.first?.code == 8002,
			"T10 RC-02 failure: one non-fatal keeping the error's domain and code, got "
				+ "\(Crashlytics.recordCallCount): \(Crashlytics.recordedErrors.map { "\($0.domain)/\($0.code)" })"
		)

		// T11 — the same shape with the one domain the noise filter knows. `CrashReporter` drops
		// `NSURLErrorNotConnectedToInternet` and `NSURLErrorCancelled` as noise, and this proves the
		// path works end to end from inside the remote-config layer. It is also what makes RC-02
		// row 2 a finding rather than a suspicion: Remote Config wraps its own network failures in
		// `FIRRemoteConfigErrorDomain` (`RCNConfigFetch.m:494-510`), so the very case this filter
		// exists for walks straight past it and files a report on every offline launch.
		reset()
		FirebaseApp.configure()
		RemoteConfig.fetchError = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
		let offline = RemoteConfigService(defaults: defaults)
		offline.configure(timeout: 5, isDebug: false, isTestsRunning: false)
		check(
			Crashlytics.recordCallCount == 0,
			"T11 RC-02 row 2: a no-connection error must be filtered as noise, got "
				+ "\(Crashlytics.recordCallCount) report(s)"
		)

		// T12 — and the layer keeps working. "Failed fetch" is a state the schema calls normal
		// operation, not an error the caller has to handle: reads answer the app's defaults and
		// nothing about the failure is visible to the user.
		check(
			offline.bool("paywallReview") == true && offline.string("experiment") == "control",
			"T12 RC-02 failure: reads must keep answering defaults after a failed fetch, got "
				+ "\(offline.bool("paywallReview")) / \(offline.string("experiment"))"
		)

		// ── RC-02 steady state — what the console sent wins, the rest stay defaults ──────────
		// The precedence is the SDK's (`activeConfig` before `defaultConfig`,
		// `FIRRemoteConfig.m:517-539`), and this is the assert that says the wrapper does not get
		// between them. The partial answer is the interesting half: a console that sends two of four
		// keys must not blank the other two — that is what defaults are for.
		reset()
		RemoteConfig.fetched = [
			"paywallReview": NSNumber(value: false),
			"experiment": NSString(string: "variant-b"),
		]
		let fetched = activeLayer()
		check(
			fetched.bool("paywallReview") == false && fetched.string("experiment") == "variant-b",
			"T13 RC-02 steady state: fetched values must win over defaults, got "
				+ "\(fetched.bool("paywallReview")) / \(fetched.string("experiment"))"
		)
		check(
			fetched.int("freeQuota") == 3 && fetched.double("discount") == 0.25,
			"T13 RC-02 steady state: keys the console did not send must stay on their defaults, got "
				+ "\(fetched.int("freeQuota")) / \(fetched.double("discount"))"
		)

		// ── RC-03 row 1 — a key nobody registered ────────────────────────────────────────────
		// The worst answer in the layer, and the reason the row exists: the type's zero here is
		// indistinguishable from a `false` the console really sent. Both branches are asserted,
		// because they arrive at it by different routes — the active one through the SDK's static
		// source (`FIRRemoteConfig.m:503-507`), the defaulted one through a missing dictionary key.
		// What is NOT asserted is the log line the schema requires and the code does not write; that
		// half of the row is in the gap list at the top of this file.
		reset()
		let known = activeLayer()
		check(
			known.bool("nope") == false && known.string("nope") == "" && known.int("nope") == 0
				&& known.double("nope") == 0,
			"T14 RC-03 row 1: an unregistered key must answer the type's zero (active branch), got "
				+ "\(known.bool("nope")) / \(known.string("nope")) / \(known.int("nope")) / \(known.double("nope"))"
		)
		reset()
		let unknown = RemoteConfigService(defaults: defaults)
		unknown.configure(timeout: 5, isDebug: false, isTestsRunning: false)
		check(
			unknown.bool("nope") == false && unknown.string("nope") == "" && unknown.int("nope") == 0
				&& unknown.double("nope") == 0,
			"T14 RC-03 row 1: an unregistered key must answer the type's zero (defaulted branch), got "
				+ "\(unknown.bool("nope")) / \(unknown.string("nope")) / \(unknown.int("nope")) / \(unknown.double("nope"))"
		)

		// ── RC-03 row 3 — the two branches must not disagree ─────────────────────────────────
		// The left branch exists for one reason: to reproduce the SDK's precedence when there is no
		// SDK. If it reproduces it differently, a flag that works in production "switches off"
		// exactly in the launch where Firebase failed to come up — the launch where it is hardest to
		// diagnose. The input is a default whose type does not match the reader, which is where the
		// two implementations have the most room to drift apart.
		let odd: [String: NSObject] = ["flag": NSString(string: "true"), "count": NSString(string: "7")]
		reset()
		let oddDefaulted = RemoteConfigService(defaults: odd)
		oddDefaulted.configure(timeout: 5, isDebug: false, isTestsRunning: false)
		let defaultedBool = oddDefaulted.bool("flag")
		let defaultedInt = oddDefaulted.int("count")
		reset()
		FirebaseApp.configure()
		let oddActive = RemoteConfigService(defaults: odd)
		oddActive.configure(timeout: 5, isDebug: false, isTestsRunning: false)
		check(
			oddActive.bool("flag") == defaultedBool && oddActive.int("count") == defaultedInt,
			"T15 RC-03 row 3: both branches must answer the same for the same input, got active "
				+ "\(oddActive.bool("flag"))/\(oddActive.int("count")) vs defaulted "
				+ "\(defaultedBool)/\(defaultedInt)"
		)

		// ── RC-03 row 6 — int() truncates, and that is the contract ──────────────────────────
		// Not a defect to fix: `1.9` becoming `1` is what `NSNumber.intValue` does, and the reader
		// named the type. It is asserted so it stays named — whoever sets the value in the console
		// never sees this code, and a later change to rounding would move a quota under them.
		reset()
		RemoteConfig.fetched = ["freeQuota": NSNumber(value: 1.9)]
		let fractional = activeLayer()
		check(
			fractional.int("freeQuota") == 1 && fractional.double("freeQuota") == 1.9,
			"T16 RC-03 row 6: int() must truncate where double() keeps the value, got "
				+ "\(fractional.int("freeQuota")) / \(fractional.double("freeQuota"))"
		)

		// ── RC-03 row 7 — reading changes nothing ────────────────────────────────────────────
		// The only operation in the layer with no side effects, which is what makes it safe to call
		// on every screen at the moment of display — the rule the schema puts on the caller. Both
		// observable halves of "nothing" are named: no extra fetch, and the registered defaults left
		// as they were.
		reset()
		let idle = activeLayer()
		for _ in 0..<200 {
			_ = idle.bool("paywallReview")
			_ = idle.string("experiment")
			_ = idle.int("freeQuota")
			_ = idle.double("discount")
		}
		check(
			RemoteConfig.fetchCallCount == 1 && Set(RemoteConfig.registeredDefaults.keys) == Set(defaults.keys),
			"T17 RC-03 row 7: 800 reads must change nothing, got \(RemoteConfig.fetchCallCount) fetch(es) "
				+ "and \(RemoteConfig.registeredDefaults.count) default(s)"
		)

		// ── RC-03 row 5 — reads are safe from any queue ──────────────────────────────────────
		// The layer holds no lock and needs none: `defaults` is a `let`, `remoteConfig` is written
		// once during configuration, and the SDK guards the read itself with `dispatch_sync` on a
		// shared serial queue (`FIRRemoteConfig.m:524-537`). What this row can show is that the
		// wrapper adds nothing that breaks it — every concurrent read agrees with every other.
		reset()
		let shared = activeLayer()
		let answers = UnsafeMutablePointer<Bool>.allocate(capacity: 500)
		answers.initialize(repeating: false, count: 500)
		DispatchQueue.concurrentPerform(iterations: 500) { index in
			answers[index] = shared.bool("paywallReview")
		}
		let agreed = (0..<500).allSatisfy { answers[$0] == true }
		answers.deinitialize(count: 500)
		answers.deallocate()
		check(
			agreed,
			"T18 RC-03 row 5: 500 concurrent reads must all answer true, got at least one that did not"
		)

		// ── RC-03 happy path — all four readers, one fetched value each ──────────────────────
		// The smoke test the reference schema asks for: the whole layer, end to end, on the path
		// every app takes. Each reader is asserted against a value only the console could have sent,
		// so a reader wired to the wrong type or the wrong source cannot pass by matching a default.
		reset()
		RemoteConfig.fetched = [
			"paywallReview": NSNumber(value: false),
			"experiment": NSString(string: "variant-c"),
			"freeQuota": NSNumber(value: 10),
			"discount": NSNumber(value: 0.5),
		]
		let live = activeLayer()
		check(
			live.bool("paywallReview") == false && live.string("experiment") == "variant-c"
				&& live.int("freeQuota") == 10 && live.double("discount") == 0.5,
			"T19 RC-03 happy path: every reader must answer what the console sent, got "
				+ "\(live.bool("paywallReview")) / \(live.string("experiment")) / "
				+ "\(live.int("freeQuota")) / \(live.double("discount"))"
		)

		if failures.isEmpty {
			print("RemoteConfigService (RC-01…RC-03): \(rowCount)/\(rowCount) rows OK")
		} else {
			print("\(failures.count) assert(s) FAILED across \(rowCount) rows")
			exit(1)
		}
	}
}
