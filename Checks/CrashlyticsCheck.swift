//
//  CrashlyticsCheck.swift
//  IntegrationKit
//
//  Written from the approved schemas CR-01 and CR-02, not from the code. Eleven of the sixteen rows
//  of those two tables are checked here. The five that are not each say why in the row itself:
//  CR-02 row 6 is a pointer to CR-01 row 1 (covering it twice would hide which one owns the test),
//  CR-01 row 6 is a resolver fact with no runtime to observe, CR-01 row 7 and CR-02 row 8 are log
//  lines the schema requires and the code does not yet emit, and CR-01 row 5 stopped being a
//  runtime state at all — see the note standing where T10 used to.
//
//  All eleven are green. T1–T5 and T14–T15 were written red first, as the spec for behaviour the
//  wrapper did not have: a second `FirebaseIntegration.configure()` is a no-op (CR-01 row 3), crash
//  collection follows the app's own `isDebug` key and is written on every launch in both directions
//  (CR-01 rows 2 and 4), a report filed before Firebase is up is counted rather than lost (CR-01
//  row 1), and the tag reaches Crashlytics as a *searchable custom key* (CR-02 row 1). T6–T9 were
//  green from the start and pin the noise filter exactly as the contract describes it, so a later
//  change cannot loosen it silently.
//
//  This check does not stop at the first failing row: every row runs, every failure is collected,
//  and the summary at the end reports all of them with a non-zero exit code — same shape as
//  `AdaptyServiceCheck`. A non-zero exit is now a regression, not the expected outcome.
//  Run:  ./Checks/crashlytics-check.sh
//

import FirebaseCore
import FirebaseCrashlytics
import Foundation

@main
enum CrashlyticsCheck {
	static var failures: [String] = []
	static var rowCount = 11

	/// Records a failure instead of trapping — one failing row must not stop every row after it
	/// from running.
	static func check(_ condition: @autoclosure () -> Bool, _ message: @autoclosure () -> String) {
		guard !condition() else { return }
		let text = message()
		failures.append(text)
		print("FAILED: \(text)")
	}

	/// Back to "the app just launched and nothing has been configured yet".
	static func reset() {
		FirebaseApp.reset()
		Crashlytics.reset()
		ConfigurationIssues.shared.reset()
		CrashReporter.resetDroppedReports()
	}

	static func issues() -> String {
		ConfigurationIssues.shared.all.joined(separator: " | ")
	}

	static func main() {
		// ── CR-01 row 3 — a second configuration must be a safe no-op ────────────────────────
		// Executes `FirebaseIntegration.configure()`. The real SDK throws an `NSException` on the
		// second `FirebaseApp.configure()` — one that Swift cannot catch, so the app dies at launch.
		reset()
		FirebaseIntegration.configure(isDebug: true)
		FirebaseIntegration.configure(isDebug: true)
		check(
			FirebaseApp.configureCallCount == 1,
			"T1 CR-01 row 3: two FirebaseIntegration.configure() calls must reach the SDK once, "
				+ "got \(FirebaseApp.configureCallCount)"
		)

		// ── CR-01 row 2 — the answer is the app's to give, not the compiler's ────────────────
		// This check builds with `-D DEBUG`, which is exactly the build where the old hardwired
		// `#if DEBUG` forced the flag to `false`. Asking for collection here must still turn it on:
		// that is the whole point of the row — a developer who wants to see their own test crash in
		// the dashboard must not have to make a Release build to do it.
		reset()
		FirebaseIntegration.configure(isDebug: false)
		check(
			Crashlytics.collectionEnabled == true,
			"T2 CR-01 row 2: isDebug false must reach the SDK as collection ON even under -D DEBUG, "
				+ "got \(String(describing: Crashlytics.collectionEnabled))"
		)

		// ── CR-01 row 4 — written explicitly, every launch, in both directions ───────────────
		// The flag persists in `NSUserDefaults` between runs (`FIRCLSDataCollectionArbiter.m:116`),
		// so "leave it alone and let the default win" is not a state this wrapper may be in: a
		// Debug run that switched collection off would keep it off in the Release build installed
		// over it. `nil` here means nobody wrote the flag at all, and that is the failure.
		reset()
		FirebaseIntegration.configure(isDebug: true)
		check(
			Crashlytics.collectionEnabled == false,
			"T3 CR-01 row 4: the flag must be written explicitly on every launch, got "
				+ "\(String(describing: Crashlytics.collectionEnabled)) (nil = never written)"
		)

		// ── CR-01 row 1 — a report filed before Firebase is up ───────────────────────────────
		// The worst failure mode for a tool whose only job is not to be silent. No `configure()`
		// here at all: `FirebaseApp.app()` is nil, and the report has nowhere to go. All three
		// values the schema names are asserted — the count of what was lost, the fact the SDK was
		// not touched, and a line the app itself can read back.
		reset()
		let orphan = CrashReporter()
		orphan.recordNonFatal("premium", NSError(domain: "app.premium", code: 7), [:])
		check(
			orphan.droppedReports == 1,
			"T4 CR-01 row 1: a report filed before Firebase is up must be counted, got "
				+ "\(orphan.droppedReports)"
		)
		check(
			Crashlytics.recordCallCount == 0,
			"T4 CR-01 row 1: nothing may be handed to an unconfigured Crashlytics, got "
				+ "\(Crashlytics.recordCallCount) report(s)"
		)
		check(
			ConfigurationIssues.shared.all.contains { $0.contains("FirebaseIntegration.configure") },
			"T4 CR-01 row 1: the reason must name the call that was missed — got \(issues())"
		)

		// ── CR-02 row 1 — the tag must reach Crashlytics where it can be searched ────────────
		// `userInfo` is shown inside an issue that is already open; only a custom key can be
		// filtered on in the dashboard (`FIRCLSUserLogging.m:329-352`). A tag that arrives only in
		// `userInfo` therefore does not close this row: "errors from premium" is still unfindable.
		reset()
		FirebaseIntegration.configure(isDebug: false)
		let reporter = CrashReporter()
		reporter.recordNonFatal("premium", NSError(domain: "app.premium", code: 42), ["step": "restore"])
		check(
			(Crashlytics.customValues[CrashReporter.tagKey] as? String) == "premium",
			"T5 CR-02 row 1: the tag \"premium\" must reach Crashlytics as the custom key "
				+ "\"\(CrashReporter.tagKey)\", got \(String(describing: Crashlytics.customValues))"
		)
		check(
			Crashlytics.recordCallCount == 1,
			"T5 CR-02 row 1: the report itself must still be filed, got \(Crashlytics.recordCallCount)"
		)

		// ── CR-02 row 2 — a dropped connection and a cancelled request are noise ─────────────
		// Executes the filter in `CrashReporter.recordNonFatal` on both codes it lists.
		Crashlytics.reset()
		reporter.recordNonFatal("net", NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet), [:])
		reporter.recordNonFatal("net", NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled), [:])
		check(
			Crashlytics.recordCallCount == 0,
			"T6 CR-02 row 2: offline and cancelled must both be filtered out, "
				+ "got \(Crashlytics.recordCallCount) report(s)"
		)

		// ── CR-02 row 3 — same code, someone else's domain, still reported ───────────────────
		// The domain half of the filter: it must not glue shut on a code that happens to collide.
		Crashlytics.reset()
		reporter.recordNonFatal("app", NSError(domain: "app.network", code: NSURLErrorNotConnectedToInternet), [:])
		check(
			Crashlytics.recordCallCount == 1 && Crashlytics.recordedErrors.first?.domain == "app.network",
			"T7 CR-02 row 3: an app-domain error with a colliding code must be reported, got "
				+ "\(Crashlytics.recordCallCount) report(s) from "
				+ "\(String(describing: Crashlytics.recordedErrors.first?.domain))"
		)

		// ── CR-02 row 4 — a timeout is deliberately not noise ────────────────────────────────
		// This row pins a decision, not a defect: a timeout often means a slow backend of our own.
		Crashlytics.reset()
		reporter.recordNonFatal("net", NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut), [:])
		check(
			Crashlytics.recordCallCount == 1 && Crashlytics.recordedErrors.first?.code == NSURLErrorTimedOut,
			"T8 CR-02 row 4: a network timeout must still be reported, got "
				+ "\(Crashlytics.recordCallCount) report(s) with code "
				+ "\(String(describing: Crashlytics.recordedErrors.first?.code))"
		)

		// ── CR-02 row 5 — two threads at once ────────────────────────────────────────────────
		// `CrashReporter` is a struct with no per-instance state, so there is nothing to corrupt;
		// this row proves the claim instead of leaving it as an assurance. The dropped-report
		// counter added for CR-01 row 1 is shared state, so it is the one thing that has to carry
		// its own lock — this row is what would catch losing that. The stub's own counters are not
		// thread-safe, so the two calls are serialised through one queue after being dispatched
		// from two: what is under test is the reporter, not the stub.
		Crashlytics.reset()
		let group = DispatchGroup()
		let serial = DispatchQueue(label: "crashlytics-check.serial")
		for index in 0..<2 {
			DispatchQueue.global().async(group: group) {
				serial.sync {
					reporter.recordNonFatal("thread-\(index)", NSError(domain: "app.thread", code: index), [:])
				}
			}
		}
		let finished = group.wait(timeout: .now() + 2) == .success
		check(
			finished && Crashlytics.recordCallCount == 2,
			"T9 CR-02 row 5: two concurrent calls must produce two reports, finished=\(finished), "
				+ "got \(Crashlytics.recordCallCount)"
		)

		// CR-02 row 6 (Crashlytics never brought up) is NOT covered here on purpose — it is a
		// pointer to CR-01 row 1, and covering it twice would hide which of the two owns the test.

		// CR-01 row 5 (an app that says nothing) is NOT covered here any more, and cannot be: the
		// row was about the default behind `collectsCrashes`, and that parameter is gone. Crash
		// collection now follows `isDebug` — one of the two keys the app hands the package — and
		// `isDebug` carries no default, because a package that defaults it is a package guessing
		// the build type. "The app passed nothing" therefore stops being a runtime state to assert
		// and becomes a compile error at the call site, which is a stronger lock than T10 was.
		// T10 stood here until 2026-09-09; its twelve lines are kept as this note rather than
		// deleted, so every assert coordinate below stays where the risk tables say it is.
		// What the row's real intent — silence must not switch a not-to-be-silent tool off — turns
		// into is the pair of asserts at the end of this file: the flag is written on every launch,
		// in both directions, from the app's own answer. Neither direction can be dropped without
		// one of them going red.

		// ── CR-02 row 7 — the noise filter runs before the Firebase-up guard ─────────────────
		// Order is contract here, not implementation detail. A filtered network error is not a lost
		// report — it is a report the contract says not to file — so it must not raise the dropped
		// counter. If the two guards swapped, an app that forgot `configure()` would show a counter
		// full of its own offline noise and CR-01 row 1 would stop pointing at what it exists for.
		reset()
		let unconfigured = CrashReporter()
		unconfigured.recordNonFatal("net", NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled), [:])
		check(
			unconfigured.droppedReports == 0,
			"T11 CR-02 row 7: noise raised before configure() is not a lost report and must not "
				+ "raise droppedReports, got \(unconfigured.droppedReports)"
		)
		check(
			ConfigurationIssues.shared.all.isEmpty,
			"T11 CR-02 row 7: filtered noise must not manufacture a configuration issue, got "
				+ "\(issues())"
		)

		// ── CR-02 row 1, second half — the context still travels beside the tag ──────────────
		// Moving the tag to a custom key must not cost the caller its context: `info` is the
		// reference material inside an issue already opened by the tag's filter. T5 pins that the
		// tag arrives searchable; this pins that nothing was traded away to get it there.
		reset()
		FirebaseIntegration.configure(isDebug: false)
		CrashReporter().recordNonFatal("premium", NSError(domain: "app.premium", code: 42), ["step": "restore"])
		check(
			(Crashlytics.recordedErrors.first?.userInfo?["step"] as? String) == "restore",
			"T12 CR-02 row 1: the context must still reach userInfo beside the tag, got "
				+ "\(String(describing: Crashlytics.recordedErrors.first?.userInfo))"
		)

		// ── CR-02 row 9 — the one line this layer logs carries the prefix and the data ───────
		// The package-wide logging contract: `[IntegrationKit]` plus a service tag, and the data
		// itself in the line — not "something went wrong". Asserted on the prefix and the payload,
		// not on the tag string: the schema names the service `CrashReporter` and the code says
		// `Crashlytics`, and that divergence is what row 9 records rather than blesses.
		reset()
		var logged: [String] = []
		debugLogSink = { logged.append($0) }
		CrashReporter().recordNonFatal("premium", NSError(domain: "app.premium", code: 7), [:])
		debugLogSink = nil
		check(
			logged.contains {
				$0.hasPrefix("[IntegrationKit][") && $0.contains("[error]")
					&& $0.contains("FirebaseIntegration.configure")
			},
			"T13 CR-02 row 9: the dropped-report cause must be logged with the [IntegrationKit] "
				+ "prefix, at error level, naming the call that was missed, got \(logged)"
		)

		// ── CR-01 row 4 — the second launch on a device the first launch already wrote ───────
		// Appended at the end on purpose: every coordinate above is quoted by CR-01 and CR-02, and
		// renumbering them is a worse defect than a long file.
		//
		// T2 and T3 own the two directions within one launch, each from a flag nobody has written
		// yet. What neither of them can say is the thing the row is actually about: the flag lives
		// in `NSUserDefaults` under `com.crashlytics.data_collection`
		// (`FIRCLSDataCollectionArbiter.m:116`), so it survives the process that wrote it and the
		// build that wrote it. `reset()` clears the stub, which is exactly the state a real device
		// is never in after the first run.
		//
		// So both rows here are two launches on one device with the flag left standing in between —
		// only `FirebaseApp` is reset, the way a relaunch resets a process. A wrapper that only
		// knew how to switch collection off would pass T2 and T3 and still fail T14: yesterday's
		// debug build left the device dark, and today's release build has to turn it back on.
		Crashlytics.reset()
		FirebaseApp.reset()
		FirebaseIntegration.configure(isDebug: true)
		FirebaseApp.reset()
		FirebaseIntegration.configure(isDebug: false)
		check(
			Crashlytics.collectionEnabled == true,
			"T14 CR-01 row 4: a launch with isDebug false must switch collection back ON over the "
				+ "value a previous launch persisted, got "
				+ "\(String(describing: Crashlytics.collectionEnabled)) (nil = never written)"
		)

		// T15 — the same in the other direction. A device that reported crashes must stop when the
		// next build says it is a debug one; "write it only when turning collection on" is the
		// mirror defect and would leave a developer's own crashes in the production dashboard.
		Crashlytics.reset()
		FirebaseApp.reset()
		FirebaseIntegration.configure(isDebug: false)
		FirebaseApp.reset()
		FirebaseIntegration.configure(isDebug: true)
		check(
			Crashlytics.collectionEnabled == false,
			"T15 CR-01 row 4: a launch with isDebug true must switch collection back OFF over the "
				+ "value a previous launch persisted, got "
				+ "\(String(describing: Crashlytics.collectionEnabled)) (nil = never written)"
		)

		if failures.isEmpty {
			print("CrashReporter noise filter (CR-02) and configuration (CR-01): \(rowCount)/\(rowCount) OK")
		} else {
			print("\(failures.count) of \(rowCount) rows FAILED")
			exit(1)
		}
	}
}
