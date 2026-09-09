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

	/// An app shipped without attribution: every key empty, which is the documented legal
	/// configuration. `appsFlyerDevKey` empty is what leaves `IntegrationKit` holding no
	/// `AppsFlyerService` at all.
	static func kitWithoutAppsFlyer() -> IntegrationKit {
		IntegrationKit.configure(
			deviceId: "00000000-0000-0000-0000-000000000000",
			amplitudeKey: "",
			adaptyKey: "",
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

		if failures.isEmpty {
			print("IntegrationKit composition root (AF-05 through the facade): 3/3 OK")
		} else {
			print("\(failures.count) check(s) failed:")
			for failure in failures {
				print("  - \(failure)")
			}
			exit(1)
		}
	}
}
