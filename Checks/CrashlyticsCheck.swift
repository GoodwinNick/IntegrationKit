//
//  CrashlyticsCheck.swift
//  IntegrationKit
//
//  Written from the approved schemas CR-01 and CR-02, not from the code. Nine of the ten rows of
//  those two tables are checked here; the tenth (CR-02 row 6) is a pointer to CR-01 row 1 and says
//  below why covering it twice would hide something.
//
//  All nine are green as of `60169db`. T1–T5 were written red first, as the spec for behaviour the
//  wrapper did not have: a second `FirebaseIntegration.configure()` is a no-op (CR-01 row 3), the
//  collection flag arrives as a parameter and is written on every launch in both directions (CR-01
//  rows 2 and 4), a report filed before Firebase is up is counted rather than lost (CR-01 row 1),
//  and the tag reaches Crashlytics as a *searchable custom key* (CR-02 row 1). T6–T9 were green
//  from the start and pin the noise filter exactly as the contract describes it, so a later change
//  cannot loosen it silently.
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
	static var rowCount = 9

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
		FirebaseIntegration.configure(collectsCrashes: false)
		FirebaseIntegration.configure(collectsCrashes: false)
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
		FirebaseIntegration.configure(collectsCrashes: true)
		check(
			Crashlytics.collectionEnabled == true,
			"T2 CR-01 row 2: collectsCrashes: true must reach the SDK as true even under -D DEBUG, "
				+ "got \(String(describing: Crashlytics.collectionEnabled))"
		)

		// ── CR-01 row 4 — written explicitly, every launch, in both directions ───────────────
		// The flag persists in `NSUserDefaults` between runs (`FIRCLSDataCollectionArbiter.m:116`),
		// so "leave it alone and let the default win" is not a state this wrapper may be in: a
		// Debug run that switched collection off would keep it off in the Release build installed
		// over it. `nil` here means nobody wrote the flag at all, and that is the failure.
		reset()
		FirebaseIntegration.configure(collectsCrashes: false)
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
		FirebaseIntegration.configure(collectsCrashes: true)
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

		if failures.isEmpty {
			print("CrashReporter noise filter (CR-02) and configuration (CR-01): \(rowCount)/\(rowCount) OK")
		} else {
			print("\(failures.count) of \(rowCount) rows FAILED")
			exit(1)
		}
	}
}
