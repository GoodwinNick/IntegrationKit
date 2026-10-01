//
//  IntegrationKitCheck.swift
//  IntegrationKit
//
//  The composition root, actually run. `buildhost-check.sh` proves `IntegrationKit.swift` still
//  compiles against the real SDKs; it never executes a line of it. The other ten checks build a
//  hand-picked slice of `Sources/` and do not compile the root at all. So a forward in the facade
//  that drops a request on the floor is invisible to all eleven — which is exactly what AF-05
//  row 3 turned out to be: the SERVICE answers the system when the layer is off, and the FACADE,
//  which holds no service at all in that configuration, answered nobody.
//
//  This check builds the whole package against the same stub modules the other checks use and runs
//  the root the way an app does.
//
//  Two processes of one binary, because `configure` builds one kit per process and what it decides
//  about a test run is decided once: no argument is a normal launch (`launch()`), `--tests-running`
//  is a test run (`testRun()`, FA-01 r3 and TM-07 r10 for Firebase). The script runs them in turn.
//  Run:  ./Checks/integration-kit-check.sh
//

import Adapty
import AmplitudeSwift
import FirebaseAnalytics
import FirebaseCore
import Foundation
import UIKit

@main
enum IntegrationKitCheck {
	static var failures: [String] = []
	static var assertCount = 0

	/// Records a failure instead of trapping, same as `PremiumStoreKitCheck` — one failing row must
	/// not stop the rest from running.
	static func check(_ condition: @autoclosure () -> Bool, _ message: @autoclosure () -> String) {
		assertCount += 1
		guard !condition() else { return }
		let text = message()
		failures.append(text)
		print("FAILED: \(text)")
	}

	/// Polls instead of awaiting, the same shape `AdaptyServiceCheck` uses: `main()` is synchronous
	/// and the calls under test hand their answer back on the main run loop.
	@discardableResult
	static func wait(_ seconds: TimeInterval = 2, for condition: () -> Bool) -> Bool {
		let deadline = Date().addingTimeInterval(seconds)
		while Date() < deadline {
			if condition() { return true }
			RunLoop.current.run(until: Date().addingTimeInterval(0.005))
		}
		return condition()
	}

	/// Runs one `async` call to completion on the main run loop.
	static func run<T>(_ work: @escaping () async -> T) -> T? {
		var result: T?
		Task { result = await work() }
		wait(5) { result != nil }
		return result
	}

	/// An app shipped without attribution: `appsFlyerDevKey` empty, which is the documented legal
	/// configuration and what leaves `IntegrationKit` holding no `AppsFlyerService` at all.
	///
	/// The Adapty and Amplitude keys, on the other hand, are live-shaped, and that is not decoration:
	/// the forwards asserted below are only observable through the SDK stubs, and a layer that is off
	/// stops every one of them at its own guard before the forward can be seen at all. It has to be
	/// decided here rather than per row — `configure` builds one kit per process by design, so the
	/// first call in this file is the only call that chooses anything.
	static let deviceId = "00000000-0000-0000-0000-000000000000"

	static func kitWithoutAppsFlyer(isTestsRunning: Bool = false) -> IntegrationKit {
		IntegrationKit.configure(
			deviceId: deviceId,
			amplitudeKey: "amp-key",
			adaptyKey: "public_live_0000000000000000000000000000000000",
			placements: [],
			sessionsCounter: 1,
			productIds: [],
			isDebug: false,
			isTestsRunning: isTestsRunning,
			appsFlyerDevKey: ""
		)
	}

	static func main() {
		let testsRunning = CommandLine.arguments.contains("--tests-running")
		if testsRunning {
			testRun()
		} else {
			launch()
		}

		if failures.isEmpty {
			print("IntegrationKit composition root (\(testsRunning ? "test run" : "launch")): \(assertCount) checks OK")
		} else {
			print("\(failures.count) of \(assertCount) check(s) failed (\(testsRunning ? "test run" : "launch")):")
			for failure in failures {
				print("  - \(failure)")
			}
			exit(1)
		}
	}

	// MARK: - A test run (FA-01 r3, TM-07 r10)

	/// Firebase is up — the app does that before the kit — and the app says this is a test run. The
	/// kit must still tell Firebase to stop collecting (the flag is stored between launches, so a run
	/// that skipped it would leave collection on for the next one), and must otherwise leave it
	/// entirely alone: no event, no user id, no property, no read of the instance id for Adapty.
	static func testRun() {
		FirebaseApp.configure()
		Analytics.stubAppInstanceID = "fid-test-run"
		let kit = kitWithoutAppsFlyer(isTestsRunning: true)
		kit.analytics.logEvent("root_test_event", properties: ["k": "v"])
		kit.analytics.setUserProperties(["status": "tester"])

		check(Analytics.collectionEnabledCalls == [false],
		      "FA-01 r3: a test run must switch Firebase collection OFF, exactly once — got \(Analytics.collectionEnabledCalls)")
		check(Analytics.loggedEvents.isEmpty,
		      "TM-07 r10: a test run must send Firebase no event, not even through the facade — got \(Analytics.loggedEvents.map(\.name))")
		check(Analytics.userIDs.isEmpty && Analytics.userProperties.isEmpty,
		      "TM-07 r10: a test run must send Firebase no user id and no property — ids \(Analytics.userIDs), properties \(Analytics.userProperties.map(\.name))")
		check(Analytics.transactions.isEmpty,
		      "TM-07 r10: a test run must send Firebase no transaction — got \(Analytics.transactions)")
		check(Analytics.appInstanceIDReads == 0,
		      "FA-05: a test run must not read the Firebase instance id — it has nobody to give it to — got \(Analytics.appInstanceIDReads) read(s)")
	}

	// MARK: - A normal launch

	static func launch() {
		// FA-01, FA-03, FA-05 — what the kit does with Firebase on its own, before any call from the
		// app. Firebase is up and has an instance id ready, as in the app after
		// `FirebaseIntegration.configure`. Asserted first, while the stubs hold nothing else.
		FirebaseApp.configure()
		Analytics.stubAppInstanceID = "fid-auto"
		let kit = kitWithoutAppsFlyer()

		check(Analytics.collectionEnabledCalls == [true],
		      "FA-01: a normal launch must state collection ON, exactly once, on every launch — got \(Analytics.collectionEnabledCalls)")
		check(Analytics.userIDs == [deviceId],
		      "FA-03: the user id Firebase gets is the app's own device id, once — got \(Analytics.userIDs)")
		check(Analytics.userProperties.contains { $0.name == "environment" && $0.value == "unknown" },
		      "AN-01 r12: `environment` must reach Firebase from the root — got \(Analytics.userProperties)")
		// The id reaches Adapty by itself: no `setFirebaseAppInstanceId` call has been made by this file
		// yet, so anything in the journal came from the kit (FA-05). The activation answers a moment
		// later, hence the wait.
		wait { Adapty.integrationIdentifierJournal.contains { $0.key == .firebaseAppInstanceId } }
		let autoWrites = Adapty.integrationIdentifierJournal.filter { $0.key == .firebaseAppInstanceId }.map(\.value)
		check(autoWrites == ["fid-auto"],
		      "FA-05: the kit must hand the Firebase instance id to Adapty by itself, once, with no call from the app — got \(autoWrites)")

		// …and an event through the facade goes to BOTH SDKs, under one name (FA-02 r1, AN-02 r6).
		kit.analytics.logEvent("root_event", properties: ["plan": "year"])
		check(Amplitude.trackedEvents.last?.eventType == "root_event" && Analytics.loggedEvents.last?.name == "root_event",
		      "FA-02 r1: an event through the facade must reach Amplitude and Firebase under the same name — Amplitude \(String(describing: Amplitude.trackedEvents.last?.eventType)), Firebase \(Analytics.loggedEvents.map(\.name))")
		check(Analytics.loggedEvents.last?.parameters?["plan"] as? String == "year",
		      "FA-02 r1: the parameters must travel with it — got \(String(describing: Analytics.loggedEvents.last?.parameters))")

		// AF-05 row 3, through the facade. The schema is explicit that answering is a duty of its own:
		// "вимкнений шар теж відповідає, і відповідає рівно один раз". `restorationHandler` belongs to
		// UIKit, and an app that never calls it sits on its launch screen for the whole universal-link
		// open. `AppsFlyerServiceCheck.swift:566` and `:572` pin this for a SERVICE configured with an
		// empty dev key — but with an empty dev key the composition root builds no service, so the
		// path the app actually takes is this one and nothing covered it. (The kit itself is the one
		// built at the top of `launch()`.)
		var answers: [[UIUserActivityRestoring]?] = []
		let activity = NSUserActivity(activityType: "com.integrationkit.checks.af05")
		kit.handleContinue(activity) { answers.append($0) }
		check(answers.count == 1, "AF-05 row 3: with no AppsFlyer layer the facade must still answer the system exactly once, got \(answers.count) answer(s)")
		check(answers.first ?? nil == nil, "AF-05 row 3: the answer of a layer that was never built is empty, got \(String(describing: answers.first ?? nil))")

		// The other forward has no answer to give — `application(_:open:options:)` returns a Bool the
		// app decides on its own — so all it has to do is not trap on the missing service.
		kit.handleOpen(URL(string: "https://example.com/af05?id=1")!, options: [:])
		check(kit.droppedDeepLinks == 0, "AF-05: no AppsFlyer layer means no deep links to drop, got \(kit.droppedDeepLinks)")

		// AF-01 row 1, through the facade. `AppsFlyerService.configure` records "empty dev key" itself,
		// but with an empty key the root never builds the service, so that line is written by nobody and
		// the one place the guide tells an integrator to look stays silent about the key they forgot.
		let afReasons = kit.configurationIssues.filter { $0.contains("AppsFlyer") }
		check(afReasons.count == 1, "AF-01 row 1: an empty AppsFlyer dev key must leave exactly one readable reason in configurationIssues, got \(afReasons.count): \(afReasons)")

		// A second `configure` in one process. Nothing in the package refused it: every guard that
		// looks like it would (`isConfigured`, `didStart`, `didAddIDFAPlugin`) is an instance flag, and
		// the root builds fresh instances each time. The expensive half is silent — SwiftyStoreKit
		// ignores the second `completeTransactions` and keeps the first, so the kit the app goes on to
		// hold has no delivery path for an interrupted purchase, and the user who paid never gets it.
		let second = kitWithoutAppsFlyer()
		check(kit.premium as AnyObject === second.premium as AnyObject,
		      "A second configure() must hand back the kit already built, not a second graph whose premium layer the payment queue never reaches")
		let doubleReasons = kit.configurationIssues.filter { $0.contains("more than once") }
		check(doubleReasons.count == 1, "A second configure() must say so in configurationIssues, got \(doubleReasons.count)")

		// AD-06 row 8, through the facade. The write itself is covered by `AdaptyServiceCheck` (T30,
		// T30b) and needs nothing here; what is covered nowhere else is whether the app can reach it
		// at all. `AdaptyServicing` is internal, so until 0.2.1 an app migrating onto the package
		// simply lost the custom attributes it used to write — `purchasePlace` after every purchase —
		// and lost them silently: the app still builds, still sells, and only the segmentation on the
		// dashboard goes empty. An operation the app cannot reach equals an operation that is not there.
		//
		// The assert names the GROWTH of the journal, not its emptiness: `configure` has already
		// written the ATT status and the Amplitude link by this point.
		let beforeAttribute = Adapty.updateProfileJournal.count
		kit.setProfileValue(value: "onboarding_paywall", key: "purchasePlace")
		check(Adapty.updateProfileJournal.count == beforeAttribute + 1,
		      "AD-06 r8: setProfileValue on the facade must reach the SDK exactly once — journal \(beforeAttribute) → \(Adapty.updateProfileJournal.count)")
		let written = Adapty.updateProfileJournal.last?.customAttributes["purchasePlace"]
		check(written == .string("onboarding_paywall"),
		      "AD-06 r8: the forward must carry the app's own value and key, not a rewritten pair — got \(String(describing: written))")

		// AD-07 row 3, inverted by the migration. 4.1.3 deleted `logShowOnboarding` outright — the
		// event does not exist in the SDK any more, and the Onboarding Builder that replaced it needs a
		// placement, a fetched onboarding and a hosted view controller, none of which this package has
		// or wants. So the method stays on the facade as a DEPRECATED no-op: an app that still calls it
		// keeps compiling and keeps working, with a warning telling it the call now does nothing.
		//
		// This is the only place that can prove the no-op is really a no-op. The three asserts are the
		// three ways it could stop being one: it could reach the SDK, it could write a reason nobody can
		// act on, or it could trap on a step number the old guard used to reject — and the ТЗ asks for
		// an empty body with no guards at all, so all three must stay flat.
		let beforeOnboardingWrites = Adapty.updateProfileJournal.count
		let beforeOnboardingIssues = kit.configurationIssues.count
		kit.logOnboardingOpen(step: 1)
		kit.logOnboardingOpen(step: 0)
		kit.logOnboardingOpen(step: -1)
		check(Adapty.updateProfileJournal.count == beforeOnboardingWrites && Adapty.logShowFlowJournal.isEmpty,
		      "AD-07 r3: the deprecated logOnboardingOpen must reach the SDK with nothing at all — journal \(beforeOnboardingWrites) → \(Adapty.updateProfileJournal.count), impressions \(Adapty.logShowFlowJournal)")
		check(kit.configurationIssues.count == beforeOnboardingIssues,
		      "AD-07 r3: a no-op has nothing to report — configurationIssues \(beforeOnboardingIssues) → \(kit.configurationIssues.count)")

		// AD-06 row 12 and AD-05 row 9, through the facade — the same hole as row 8, twice over. Both
		// members are new in 0.4.1 and both exist only because an app asked for them, so an unreachable
		// forward would not be a degraded feature, it would be the whole feature missing. What they do
		// once they arrive is covered by `AdaptyServiceCheck` (T47…T56); this is about arriving.
		let beforeFirebase = Adapty.integrationIdentifierJournal.count
		kit.setFirebaseAppInstanceId("fid-facade")
		let firebaseWrites = Adapty.integrationIdentifierJournal.filter { $0.key == .firebaseAppInstanceId }
		// Since 0.8.0 the kit has already written its own id by now ("fid-auto", asserted at the top), so
		// the journal holds both, the app's last — the forward must neither swallow the app's id because
		// one is there already, nor rewrite it.
		check(firebaseWrites.map(\.value) == ["fid-auto", "fid-facade"],
		      "AD-06 r12: setFirebaseAppInstanceId on the facade must reach the SDK with the app's own id, after the kit's own — journal \(beforeFirebase) → \(Adapty.integrationIdentifierJournal.count), Firebase writes \(firebaseWrites.map(\.value))")

		// The assert names the id, not "something came back": a forward wired to the wrong call would
		// still answer a string, and `profileId()` answering `nil` is a legal answer everywhere else.
		Adapty.getProfileResult = .success(AdaptyProfile(profileId: "prof-facade", accessLevels: [:]))
		let forwardedId = run { await kit.adaptyProfileId() }
		check(forwardedId == "prof-facade",
		      "AD-05 r9: adaptyProfileId on the facade must answer the profile's own id — got \(String(describing: forwardedId))")

		// AD-06 row 8 and AN-03 row 6, in one call. `setUserProperty` is the only member of the whole
		// facade that writes to two SDKs at once, which is exactly why it is checked here and not in
		// either single-SDK check: a forward that quietly lost one half would still look completely
		// healthy from the other one's side. Both halves are named, one assert each.
		let beforeShared = Adapty.updateProfileJournal.count
		let beforeIdentify = Amplitude.identifyCalls.count
		kit.setUserProperty(value: "returning", key: "cohort")
		let sharedAdaptyValue = Adapty.updateProfileJournal.last?.customAttributes["cohort"]
		let adaptyGrew = Adapty.updateProfileJournal.count == beforeShared + 1
		check(adaptyGrew && sharedAdaptyValue == .string("returning"),
		      "AD-06 r8: setUserProperty must reach the Adapty profile with the app's own pair — journal \(beforeShared) → \(Adapty.updateProfileJournal.count), value \(String(describing: sharedAdaptyValue))")
		let sharedAmplitudeValue = Amplitude.identifyCalls.last?["cohort"] as? String
		let amplitudeGrew = Amplitude.identifyCalls.count == beforeIdentify + 1
		check(amplitudeGrew && sharedAmplitudeValue == "returning",
		      "AN-03 r6: setUserProperty must reach Amplitude with the same pair — identify calls \(beforeIdentify) → \(Amplitude.identifyCalls.count), value \(String(describing: sharedAmplitudeValue))")
	}
}
