//
//  App.swift
//  BuildHost
//
//  The consumer side of the boundary. This app is never run — it exists so the compiler proves
//  that the public API is enough to wire IntegrationKit up. If anything here needed a type the
//  package keeps internal, the build would say so.
//

import AppTrackingTransparency
import IntegrationKit
import SwiftUI
import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {

	private var kit: IntegrationKit?

	func application(
		_ application: UIApplication,
		didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
	) -> Bool {
		// The app's two keys, and the only two switches the package has. Both are computed here,
		// because both are facts only the app can see.
		#if DEBUG
			let isDebug = true
		#else
			let isDebug = false
		#endif
		// A UI test run under `-uitest`, or a unit test run, which XCTest announces by putting
		// `XCTestConfigurationFilePath` in the environment. Either one silences Amplitude, Adapty
		// and AppsFlyer for the whole run.
		let isTestsRunning = ProcessInfo.processInfo.arguments.contains("-uitest")
			|| ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

		// Crash collection is on exactly when `isDebug` is false, and it applies from the *next*
		// launch — Crashlytics writes the flag into NSUserDefaults and reads it while starting up.
		// Pass `false` from a debug build to check a live crash. `isTestsRunning` deliberately does
		// not reach here: a test run must not be the run that loses the crashes it went to catch.
		FirebaseIntegration.configure(isDebug: isDebug)

		let kit = IntegrationKit.configure(
			deviceId: "00000000-0000-0000-0000-000000000000",
			amplitudeKey: ObfuscatedSecret.reveal(encrypted: "", secret: "fake-secret"),
			adaptyKey: "public_live_fake_adapty_key",
			placements: ["main", "onboarding"],
			sessionsCounter: 1,
			sharedSecret: "00000000000000000000000000000000",
			productIds: ["year.sub", "week.sub"],
			isDebug: isDebug,
			isTestsRunning: isTestsRunning,
			levels: ["premium"],
			firstOpenEvent: "first_open",
			appsFlyerDevKey: "fakeDevKey",
			appsFlyerAppId: "1234567890",
			attTimeout: 120,
			// The app's own keys — the package names none. Every key read below has a default here,
			// because a key without one answers `false`/`""`/`0` and nothing tells that apart from a
			// value the console actually sent.
			remoteConfigDefaults: [
				"paywallReview": NSNumber(value: false),
				"onboardingVariant": NSString(string: "control"),
				"freeGenerations": NSNumber(value: 3),
				"discountRate": NSNumber(value: 0.5)
			],
			// Handed straight through. A cold launch that came from a Universal Link carries it in
			// here, and AppsFlyer holds the first session until that link resolves only if it gets it.
			launchOptions: launchOptions
		)
		self.kit = kit

		NotificationCenter.default.addObserver(
			forName: .premiumDidChange,
			object: nil,
			queue: .main
		) { _ in
			print("premium is now \(kit.premium.isPremium)")
		}

		kit.analytics.logEvent("app_open")
		kit.crashes.recordNonFatal("launch", NSError(domain: "BuildHost", code: 1))
		// Reports filed before Firebase was up are counted rather than logged away: a release build
		// can read this and know the two `configure` calls ran in the wrong order.
		if kit.crashes.droppedReports > 0 {
			kit.analytics.logEvent("crash_reports_dropped", properties: ["count": kit.crashes.droppedReports])
		}
		return true
	}

	func application(
		_ application: UIApplication,
		continue userActivity: NSUserActivity,
		restorationHandler: @escaping ([UIUserActivityRestoring]?) -> Void
	) -> Bool {
		kit?.handleContinue(userActivity, restorationHandler: restorationHandler)
		return true
	}

	func application(_ app: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
		kit?.handleOpen(url, options: options)
		// A deep link AppsFlyer reported as found and then handed over empty is paid traffic that
		// arrives nowhere. Only the app can see it in a shipping build, so it reads the count here.
		if let dropped = kit?.droppedDeepLinks, dropped > 0 {
			kit?.analytics.logEvent("deep_links_dropped", properties: ["count": dropped])
		}
		return true
	}

	/// The pre-iOS 9 half of the same forward. Here for the same reason the rest of this host exists:
	/// an app that implements only the `options:` variant loses every open the system delivers the
	/// old way, and nothing anywhere says so.
	func application(_ application: UIApplication, open url: URL, sourceApplication: String?, annotation: Any) -> Bool {
		kit?.handleOpen(url, sourceApplication: sourceApplication, annotation: annotation)
		return true
	}

	/// Everything a paywall screen needs, from the facade alone. Every case of every public enum is
	/// spelled out rather than defaulted: an exhaustive `switch` is what turns a case added to the
	/// package into a compile error here instead of a silently unhandled state in a real app.
	func paywall() {
		guard let kit else { return }
		kit.premium.logPaywallOpen(placement: "main")

		let title: RemoteValue<String> = kit.premium.remoteValue(placement: "main", key: "title")
		switch title {
			case .value(let text): print(text)
			case .notReady: print("paywall has not arrived — ask again")
			case .noConfig: print("paywall carries no remote config")
			case .notSet: print("no such key in the config")
			case .wrongType: print("the dashboard set another type — see configurationIssues")
		}

		switch kit.premium.paywallState(placement: "main") {
			case .ready: print("draw the paywall")
			case .loading: print("spinner")
			case .unavailable: print("fall back to a hardcoded screen")
		}
		print(kit.premium.hasPaywall(placement: "main"))

		kit.premium.products(placement: "main") { products in
			print(products.map { $0.localizedPrice ?? "—" })
		}
		kit.premium.product("year.sub", placement: "main") { product in
			guard let product else { return }
			kit.premium.purchase(product.id, placement: "main") { outcome in
				switch outcome {
					case .purchased: print("premium is already \(kit.premium.isPremium)")
					case .cancelled: print("the user said no")
					case .pending: print("waiting for approval — no error, no second button")
					case .unavailable: print("hide the button, a retry fails the same way")
					case .failed: print("temporary — offer a retry")
				}
			}
		}
		kit.premium.restore { outcome in
			switch outcome {
				case .restored: print("restored, premium: \(kit.premium.isPremium)")
				case .nothingToRestore: print("nothing to restore")
				case .failed: print("restore failed")
			}
		}
		kit.premium.refresh()

		// Empty is the healthy state. Anything in here is a cause no retry will fix.
		kit.premium.configurationIssues.forEach { print("[IntegrationKit] \($0)") }
	}

	/// Answer or refusal, this call has to happen — the package holds the first AppsFlyer session
	/// until it does, because since SDK 7.0 nothing inside AppsFlyer waits for ATT any more. An app
	/// that shows the prompt and never reports the outcome spends the whole `attTimeout` and then
	/// sends the install with no IDFA.
	func askTracking() {
		ATTrackingManager.requestTrackingAuthorization { [weak self] status in
			self?.kit?.updateTrackingAuthorization(status)
		}
	}

	/// The onboarding screen and a custom attribute, from the facade alone — the two places an app
	/// writes to the Adapty profile in its own words rather than the package's.
	func onboarding(step: Int) {
		// Numbered from ONE: Adapty refuses screen order 0, and a screen counted from zero is simply
		// missing from the funnel. A screen index taken from an array is off by one on purpose.
		kit?.logOnboardingOpen(step: step + 1)
	}

	/// All four readers, from the facade alone. Read where the user has already spent a moment — a
	/// screen drawn in the first seconds of a cold launch gets the default and never re-renders.
	func remoteFlags() {
		guard let kit else { return }
		print(kit.remoteConfig.bool("paywallReview"))
		print(kit.remoteConfig.string("onboardingVariant"))
		print(kit.remoteConfig.int("freeGenerations"))
		print(kit.remoteConfig.double("discountRate"))
	}

	/// All three writers of a user property, from the facade alone — one per destination, so the
	/// compiler proves an app can pick where an attribute lands.
	func markCohort(_ cohort: String) {
		guard let kit else { return }
		// An attribute only the app can know. `lastUsedDay`, `launchSession`, `deep_link_value` and
		// — since 0.2.2 — `purchasePlace` are the package's own and are never passed in from here:
		// `purchase(_:placement:)` already carries the placement and knows whether Apple charged.
		kit.setProfileValue(value: cohort, key: "cohort")
		// Amplitude alone: a counter the paywall never segments on has no business in the Adapty
		// profile, where every attribute is a targeting slot the dashboard has to show.
		kit.analytics.setUserProperties(["logoCountGenerated": 2])
		// Both at once, for an attribute the dashboards have to agree on.
		kit.setUserProperty(value: cohort, key: "cohort")
	}

	/// Identity in both directions, from the facade alone — an app that has to describe the same
	/// user on its own backend and in two dashboards.
	func linkIdentity(appInstanceId: String?) async {
		guard let kit else { return }
		// `nil` is "Adapty has not answered", never "this user has no id" — so it is not stored and
		// not sent as an absence. Asking again later in the same run is the whole recovery.
		if let adaptyId = await kit.adaptyProfileId() {
			print("send \(adaptyId) to our own backend")
		}
		// `Analytics.appInstanceID()` in a real app: an optional, and nil while Firebase Analytics is
		// still coming up. Unwrapping that to "" would write a join key matching nothing, forever.
		if let appInstanceId {
			kit.setFirebaseAppInstanceId(appInstanceId)
		}
	}
}

@main
struct BuildHostApp: App {
	@UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate

	var body: some Scene {
		WindowGroup { Text("IntegrationKit build host") }
	}
}
