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
		check(written == "onboarding_paywall",
		      "AD-06 r8: the forward must carry the app's own value and key, not a rewritten pair — got \(written ?? "nil")")

		// AD-07 row 3, the same argument for the other new forward. The guard on the step and the two
		// traps behind it are `AdaptyServiceCheck`'s (T46…T50); this is the one place that can show the
		// public method exists and lands on the service at all.
		let beforeOnboarding = Adapty.logShowOnboardingCount
		kit.logOnboardingOpen(step: 1)
		check(Adapty.logShowOnboardingCount == beforeOnboarding + 1,
		      "AD-07 r3: logOnboardingOpen on the facade must reach the SDK exactly once — \(beforeOnboarding) → \(Adapty.logShowOnboardingCount)")
		check(Adapty.lastOnboardingName == "onboarding_1",
		      "AD-07 r3: the forward must keep the event name the apps already send — got \(Adapty.lastOnboardingName ?? "nil")")

		if failures.isEmpty {
			print("IntegrationKit composition root: \(10) checks OK")
		} else {
			print("\(failures.count) check(s) failed:")
			for failure in failures {
				print("  - \(failure)")
			}
			exit(1)
		}
	}
}
