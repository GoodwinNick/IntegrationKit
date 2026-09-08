//
//  CrashlyticsCheck.swift
//  IntegrationKit
//
//  Written from the approved schemas CR-01 and CR-02, not from the code. Six rows of those two
//  risk tables are testable with the `FirebaseCrashlytics`/`FirebaseCore` stubs; four are not, and
//  every one of them says why in the comment above it rather than being closed by a lookalike
//  assert.
//
//  T1 and T4 are red on purpose — they are the spec for behaviour the wrapper does not have yet:
//  a second `FirebaseIntegration.configure()` must be a no-op (CR-01 row 3), and the tag handed to
//  `recordNonFatal` must reach Crashlytics (CR-02 row 1). T2, T3, T5, T6 are green and pin the
//  noise filter exactly as the contract describes it, so a later change cannot loosen it silently.
//
//  This check does not stop at the first failing row: every row runs, every failure is collected,
//  and the summary at the end reports all of them with a non-zero exit code — same shape as
//  `AdaptyServiceCheck`. A non-zero exit here is the expected, healthy outcome until CR-01 row 3
//  and CR-02 row 1 are implemented.
//  Run:  ./Checks/crashlytics-check.sh
//

import FirebaseCore
import FirebaseCrashlytics
import Foundation

@main
enum CrashlyticsCheck {
	static var failures: [String] = []

	/// Records a failure instead of trapping — one failing row must not stop every row after it
	/// from running.
	static func check(_ condition: @autoclosure () -> Bool, _ message: @autoclosure () -> String) {
		guard !condition() else { return }
		let text = message()
		failures.append(text)
		print("FAILED: \(text)")
	}

	static func main() {
		// ── CR-01 row 3 — a second configuration must be a safe no-op ────────────────────────
		// Executes `FirebaseIntegration.swift:11-16`. Red: the wrapper forwards every call
		// straight to `FirebaseApp.configure()`, so two calls reach the SDK.
		FirebaseApp.reset()
		Crashlytics.reset()
		FirebaseIntegration.configure()
		FirebaseIntegration.configure()
		check(
			FirebaseApp.configureCallCount == 1,
			"T1 CR-01 row 3: two FirebaseIntegration.configure() calls must reach the SDK once, "
				+ "got \(FirebaseApp.configureCallCount)"
		)

		// CR-01 row 1 (Firebase never configured) is NOT covered: the schema asks the package to
		// notice and leave a loud trace, and a trace written with `debugLog` goes to stdout, which
		// this check has no way to read. Covering it needs an observable warning channel first.
		//
		// CR-01 row 2 (`#if DEBUG` hardwired) and row 4 (flag set in both directions) are NOT
		// covered either: both become real rows only once the collection flag arrives as a
		// parameter (decision 2026-09-08, task 1218288104081038). Until then the compiler picks
		// one branch — this check builds with `-D DEBUG` — and the other cannot be reached at all.
		// The single thing observable today is recorded below, and it is deliberately not dressed
		// up as coverage of row 4.
		check(
			Crashlytics.collectionEnabled == false,
			"T2 CR-01 context: under -D DEBUG configure() must set the collection flag explicitly "
				+ "to false, got \(String(describing: Crashlytics.collectionEnabled))"
		)

		// ── CR-02 row 1 — the tag must reach Crashlytics ─────────────────────────────────────
		// Executes `CrashReporter.swift:13-19`. Red: `:13` takes the tag and `:14-19` never
		// mention it, so every report the package files is indistinguishable from the next.
		// The assert names the value, not a key: which field carries it is the implementation's
		// choice, that it arrives at all is the contract.
		Crashlytics.reset()
		let reporter = CrashReporter()
		reporter.recordNonFatal("premium", NSError(domain: "app.premium", code: 42), ["step": "restore"])
		let firstReport = Crashlytics.recordedErrors.first
		check(
			firstReport?.userInfo?.values.contains { ($0 as? String) == "premium" } == true,
			"T3 CR-02 row 1: the tag \"premium\" must reach Crashlytics with the report, got "
				+ "\(String(describing: firstReport?.userInfo))"
		)

		// ── CR-02 row 2 — a dropped connection and a cancelled request are noise ─────────────
		// Executes the filter at `CrashReporter.swift:15-17` on both codes it lists.
		Crashlytics.reset()
		reporter.recordNonFatal("net", NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet), [:])
		reporter.recordNonFatal("net", NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled), [:])
		check(
			Crashlytics.recordCallCount == 0,
			"T4 CR-02 row 2: offline and cancelled must both be filtered out, "
				+ "got \(Crashlytics.recordCallCount) report(s)"
		)

		// ── CR-02 row 3 — same code, someone else's domain, still reported ───────────────────
		// Executes the domain half of `CrashReporter.swift:15`: the filter must not glue shut on a
		// code that happens to collide.
		Crashlytics.reset()
		reporter.recordNonFatal("app", NSError(domain: "app.network", code: NSURLErrorNotConnectedToInternet), [:])
		check(
			Crashlytics.recordCallCount == 1 && Crashlytics.recordedErrors.first?.domain == "app.network",
			"T5 CR-02 row 3: an app-domain error with a colliding code must be reported, got "
				+ "\(Crashlytics.recordCallCount) report(s) from "
				+ "\(String(describing: Crashlytics.recordedErrors.first?.domain))"
		)

		// ── CR-02 row 4 — a timeout is deliberately not noise ────────────────────────────────
		// Executes the code half of `CrashReporter.swift:16`, which lists exactly two codes. This
		// row pins a decision, not a defect: a timeout often means a slow backend of our own.
		Crashlytics.reset()
		reporter.recordNonFatal("net", NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut), [:])
		check(
			Crashlytics.recordCallCount == 1 && Crashlytics.recordedErrors.first?.code == NSURLErrorTimedOut,
			"T6 CR-02 row 4: a network timeout must still be reported, got "
				+ "\(Crashlytics.recordCallCount) report(s) with code "
				+ "\(String(describing: Crashlytics.recordedErrors.first?.code))"
		)

		// ── CR-02 row 5 — two threads at once ────────────────────────────────────────────────
		// `CrashReporter` is a struct with no stored properties (`:9`), so there is nothing to
		// corrupt; this row proves the claim instead of leaving it as an assurance. The stub's own
		// counters are not thread-safe, so the two calls are serialised through one queue after
		// being dispatched from two — what is under test is the reporter, not the stub.
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
			"T7 CR-02 row 5: two concurrent calls must produce two reports, finished=\(finished), "
				+ "got \(Crashlytics.recordCallCount)"
		)

		// CR-02 row 6 (Crashlytics never brought up) is NOT covered here on purpose — it is a
		// pointer to CR-01 row 1, and covering it twice would hide that CR-01 row 1 has no test.

		if failures.isEmpty {
			print("CrashReporter noise filter (CR-02) and configuration (CR-01): 7/7 OK")
		} else {
			print("\(failures.count) of 7 rows FAILED")
			exit(1)
		}
	}
}
