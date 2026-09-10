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
//  Run:  ./Checks/integration-kit-check.sh
//

import Adapty
import Foundation
import UIKit

@main
enum IntegrationKitCheck {
	static var failures: [String] = []

	/// Records a failure instead of trapping, same as `PremiumStoreKitCheck` — one failing row must
	/// not stop the rest from running.
	static func check(_ condition: @autoclosure () -> Bool, _ message: @autoclosure () -> String) {
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
	/// The Adapty key, on the other hand, is live-shaped, and that is not decoration: the forwards
	/// asserted below are only observable through the SDK stub, and an inactive Adapty layer stops
	/// every one of them at its own `guard isActive` before the forward can be seen at all. It has to
	/// be decided here rather than per row — `configure` builds one kit per process by design, so the
	/// first call in this file is the only call that chooses anything.
	static func kitWithoutAppsFlyer() -> IntegrationKit {
		IntegrationKit.configure(
			deviceId: "00000000-0000-0000-0000-000000000000",
			amplitudeKey: "",
			adaptyKey: "public_live_0000000000000000000000000000000000",
			placements: [],
			sessionsCounter: 1,
			sharedSecret: "",
			productIds: [],
			isDebug: false,
			isTestsRunning: false,
			appsFlyerDevKey: ""
		)
	}

	static func main() {
		// AF-05 row 3, through the facade. The schema is explicit that answering is a duty of its own:
		// "вимкнений шар теж відповідає, і відповідає рівно один раз". `restorationHandler` belongs to
		// UIKit, and an app that never calls it sits on its launch screen for the whole universal-link
		// open. `AppsFlyerServiceCheck.swift:566` and `:572` pin this for a SERVICE configured with an
		// empty dev key — but with an empty dev key the composition root builds no service, so the
		// path the app actually takes is this one and nothing covered it.
		let kit = kitWithoutAppsFlyer()
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
		check(firebaseWrites.map(\.value) == ["fid-facade"],
		      "AD-06 r12: setFirebaseAppInstanceId on the facade must reach the SDK with the app's own id — journal \(beforeFirebase) → \(Adapty.integrationIdentifierJournal.count), Firebase writes \(firebaseWrites.map(\.value))")

		// The assert names the id, not "something came back": a forward wired to the wrong call would
		// still answer a string, and `profileId()` answering `nil` is a legal answer everywhere else.
		Adapty.getProfileResult = .success(AdaptyProfile(profileId: "prof-facade", accessLevels: [:]))
		let forwardedId = run { await kit.adaptyProfileId() }
		check(forwardedId == "prof-facade",
		      "AD-05 r9: adaptyProfileId on the facade must answer the profile's own id — got \(String(describing: forwardedId))")

		if failures.isEmpty {
			print("IntegrationKit composition root: \(12) checks OK")
		} else {
			print("\(failures.count) check(s) failed:")
			for failure in failures {
				print("  - \(failure)")
			}
			exit(1)
		}
	}
}
