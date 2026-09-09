//
//  IntegrationKit.swift
//  IntegrationKit
//
//  Composition root. Spec 3.5: exactly three protocols are public — `PremiumServicing`,
//  `AnalyticsTracking`, `CrashReporting`. Adapty and AppsFlyer are internal, so the app can no
//  longer wire the services itself (a public initializer cannot take an internal type). This
//  builds them instead, in the one order that works: Amplitude first, because Adapty links its
//  own profile to the Amplitude device id, then Adapty, then AppsFlyer, which pushes attribution
//  into both. Firebase stays a separate `FirebaseIntegration.configure()` — it holds nothing.
//

import AppTrackingTransparency
import Foundation
import UIKit

/// Everything the app is given, in one value: the three protocols, the `AppDelegate` forwards and
/// the package's own diagnostics. Build it once with ``configure(deviceId:amplitudeKey:adaptyKey:placements:sessionsCounter:sharedSecret:productIds:isDebug:isTestsRunning:levels:firstOpenEvent:appsFlyerDevKey:appsFlyerAppId:sourceTimeout:attTimeout:)``
/// and keep it for as long as the app runs.
public struct IntegrationKit {
	private static let tag = "IntegrationKit"

	/// The one kit this process builds, held so that neither of the two ways an app can get the
	/// lifetime wrong costs it money.
	///
	/// A second `configure` used to build a whole second graph. Nothing refused it: every guard that
	/// looks like it would — `isConfigured`, `didStart`, `didAddIDFAPlugin` — is an instance flag,
	/// and this method makes fresh instances each time. The expensive half was silent, because
	/// SwiftyStoreKit keeps the *first* `completeTransactions` and ignores every later one: the kit
	/// the app went on to hold had no delivery path for an interrupted purchase, so a user who paid
	/// simply never got it. The cheaper half was a second `didBecomeActive` observer refreshing
	/// paywalls twice for the rest of the process, and a second Adapty profile fetch and Apple
	/// receipt validation per call.
	///
	/// The other way is dropping the returned value. `AppsFlyerLib` holds both of its delegates
	/// weakly and the foreground observer does not own the service either, so the struct was the
	/// only strong reference: attribution, sessions and deep links died with nothing logged.
	/// `AdaptyService` already keeps itself alive this way for the same reason; this is that, one
	/// level up, for the whole graph.
	private static var built: IntegrationKit?

	/// The premium layer: `isPremium`, purchases, restore, prices and paywall state.
	public let premium: PremiumServicing
	/// The analytics layer: events and user properties.
	public let analytics: AnalyticsTracking
	/// The crash layer: non-fatal reports, and how many were dropped.
	public let crashes: CrashReporting

	// Kept only to stay alive and to back the forwards below — never handed out. AppsFlyer is
	// optional because an app without a dev key simply has no attribution.
	private let adapty: AdaptyServicing
	private let appsFlyer: AppsFlyerServicing?
	/// The `didBecomeActive` paywall-retry token. Holding it is not what keeps the observation
	/// alive — `NotificationCenter` retains the block-based observer itself, whether or not anyone
	/// keeps the token, and the block retains the Adapty layer with it. It is kept because it is
	/// the only handle that could ever remove the observation, and a struct has no `deinit` to do
	/// that from: the observation lasts the process, by construction.
	private let adaptyRefreshObserver: NSObjectProtocol

	/// Builds and starts the whole layer. Call `FirebaseIntegration.configure()` before this one.
	///
	/// Keys arrive as plain strings: an app that ships them obfuscated reveals them with
	/// `ObfuscatedSecret.reveal` first — the package never guesses where they came from.
	/// `deviceId` is the app's own stable id, shared by Amplitude, Adapty and AppsFlyer so all
	/// three describe the same user.
	///
	/// `sharedSecret` is the App Store Connect shared secret used to validate the receipt, and
	/// `productIds` are the subscriptions to look for inside it. An empty secret simply turns
	/// receipt validation off — Adapty then decides premium alone.
	///
	/// `sourceTimeout` is how long a premium refresh waits for one source — Adapty or the Apple
	/// receipt — before deciding without it. Five seconds is a number from practice, not one Adapty
	/// documents; an app on a worse network passes its own instead of patching the package.
	///
	/// `attTimeout` is how long AppsFlyer holds the install data waiting for the ATT answer. The
	/// documented values are scenario-dependent — 60 s when the prompt is shown at launch, 120 s
	/// when it comes after a tutorial — so only the app can choose.
	///
	/// `isDebug` and `isTestsRunning` are the app's two keys, and every SDK in the package runs off
	/// them — there is no third switch anywhere, and neither carries a default, because a default
	/// would be the package guessing something only the app can see:
	///
	/// - `isDebug` is the app's own `#if DEBUG`. It decides crash collection over in
	///   `FirebaseIntegration.configure(isDebug:)`, and it turns AppsFlyer's own console logging
	///   on and off here. An app that wants to check a live crash passes `false` from a debug
	///   build; AppsFlyer's docs require the logging off in a shipping build, which a release
	///   build's `false` gives for free.
	/// - `isTestsRunning` is the app's own reading of its launch — `-uitest` among the arguments,
	///   or `XCTestConfigurationFilePath` in the environment. `true` leaves Amplitude, Adapty and
	///   AppsFlyer down for the whole run, each recording its own reason. Firebase stays up: a test
	///   run that was meant to catch crashes must not be the run that loses them. StoreKit is not
	///   restricted by either key.
	///
	/// `adaptyAttributionEnabled` switches on Adapty's own attribution service, new in Adapty 4.x.
	/// It is off unless asked for, and that is the one default here that has to be argued rather than
	/// inherited: an app that already runs AppsFlyer would otherwise start sending a second,
	/// independent install signal nobody wired up, competing with the attribution this package
	/// forwards by hand. Adapty's own default is off too.
	public static func configure(
		deviceId: String,
		amplitudeKey: String,
		adaptyKey: String,
		placements: [String],
		sessionsCounter: Int,
		sharedSecret: String,
		productIds: Set<String>,
		isDebug: Bool,
		isTestsRunning: Bool,
		levels: Set<String> = ["premium"],
		firstOpenEvent: String? = nil,
		appsFlyerDevKey: String = "",
		appsFlyerAppId: String = "",
		sourceTimeout: TimeInterval = 5,
		attTimeout: TimeInterval = 60,
		adaptyAttributionEnabled: Bool = false
	) -> IntegrationKit {
		if let built {
			ConfigurationIssues.shared.record(
				"IntegrationKit.configure was called more than once — the kit built by the first call is returned and these arguments are ignored",
				tag: Self.tag
			)
			return built
		}
		let analytics = AmplitudeAnalytics(isDebug: isDebug)
		analytics.configure(apiKey: amplitudeKey, deviceId: deviceId, firstOpenEvent: firstOpenEvent, isTestsRunning: isTestsRunning)

		let adapty = AdaptyService()
		adapty.configure(
			apiKey: adaptyKey,
			customerUserId: deviceId,
			sessionsCounter: sessionsCounter,
			placements: placements,
			analytics: analytics,
			// AD-06 row 6: the current answer, on every launch. Read here rather than inside the
			// service — the app already owns this value and forwards it through
			// `updateTrackingAuthorization(_:)`, and the read itself is a system call the service
			// has no business making on its own.
			attStatus: ATTrackingManager.trackingAuthorizationStatus,
			isTestsRunning: isTestsRunning,
			adaptyAttributionEnabled: adaptyAttributionEnabled
		)
		// Adapty's own paywall fetch can lose a race at cold start (flaky network, cold CDN) — retry
		// every placement that is still missing each time the app comes back to the foreground.
		let adaptyRefreshObserver = NotificationCenter.default.addObserver(
			forName: UIApplication.didBecomeActiveNotification,
			object: nil,
			queue: .main
		) { _ in
			adapty.refreshPaywalls()
		}

		var appsFlyer: AppsFlyerService?
		if !appsFlyerDevKey.isEmpty {
			let service = AppsFlyerService(analytics: analytics, adapty: adapty)
			service.configure(
				devKey: appsFlyerDevKey,
				appId: appsFlyerAppId,
				deviceId: deviceId,
				attTimeout: attTimeout,
				isDebug: isDebug,
				isTestsRunning: isTestsRunning
			)
			appsFlyer = service
		} else {
			// AF-01 row 1. The service records this itself, but only a service that was built — and
			// an empty dev key is exactly the case where none is. Written here so the forgotten key
			// has a reason in the one list the guide tells an integrator to read, with the same text
			// the service would have used, so the two can never read as different causes.
			ConfigurationIssues.shared.record(
				"AppsFlyer got an empty dev key — attribution and deep links are off for this run",
				tag: "AppsFlyer"
			)
		}

		let storeKit = StoreKitService(sharedSecret: sharedSecret, productIds: productIds)
		// `productIds` has to reach here too, not just StoreKit: it is the fallback list `products`
		// prices directly when Adapty's own listing for a placement comes back empty, and an empty
		// list would leave an unloaded paywall with no prices at all.
		let premium = PremiumService(
			adapty: adapty,
			apple: storeKit,
			levels: levels,
			sourceTimeout: sourceTimeout,
			productIds: productIds
		)
		// Started here on purpose: the seed-cache-then-refresh step is not a decision the app
		// gets to make differently, and a composition root that leaves it to be forgotten is
		// the defect this rewrite exists to remove.
		premium.start()
		// The same argument, one level down: a purchase interrupted mid-flight is delivered by
		// the payment queue, not by any call above, and it stays stuck in that queue until it is
		// finished. Re-asking afterwards is what turns it into premium in this launch instead of
		// the next one.
		storeKit.completeTransactions { [weak premium] in premium?.purchaseDelivered() }

		let kit = IntegrationKit(
			premium: premium,
			analytics: analytics,
			crashes: CrashReporter(),
			adapty: adapty,
			appsFlyer: appsFlyer,
			adaptyRefreshObserver: adaptyRefreshObserver
		)
		built = kit
		return kit
	}

	// MARK: - AppDelegate forwards.
	// The app physically needs these — a deep link arrives at the app, not at the package — but
	// they travel through the kit so `AppsFlyerServicing` stays internal.

	/// Forwards `application(_:continue:restorationHandler:)`.
	///
	/// AF-05 row 3: answering is a duty of its own and does not depend on the layer being up.
	/// `restorationHandler` belongs to UIKit — an app that never calls it leaves the system waiting
	/// and the user looking at the launch screen for the whole universal-link open. An app without a
	/// dev key has no service to forward to, so the answer is given here, once, and empty. The gate
	/// inside `AppsFlyerService` stays where it is: it covers the other path, a service that exists
	/// but was configured with an empty key.
	public func handleContinue(_ userActivity: NSUserActivity, restorationHandler: @escaping ([UIUserActivityRestoring]?) -> Void) {
		guard let appsFlyer else {
			restorationHandler(nil)
			return
		}
		appsFlyer.handleContinue(userActivity, restorationHandler: restorationHandler)
	}

	/// Forwards `application(_:open:options:)`.
	public func handleOpen(_ url: URL, options: [UIApplication.OpenURLOptionsKey: Any]) {
		appsFlyer?.handleOpen(url, options: options)
	}

	/// The ATT answer reaches both SDKs that cannot read it themselves. Adapty's half would be
	/// unreachable otherwise, now that the app cannot hold an `AdaptyServicing`.
	public func updateTrackingAuthorization(_ status: ATTrackingManager.AuthorizationStatus) {
		analytics.updateTrackingAuthorization(status)
		adapty.updateAppTrackingTransparencyStatus(status)
	}

	// MARK: - Adapty forwards.
	// Two operations whose input only the app has, and which no premium protocol should carry — a
	// profile attribute is not a purchase, and `PremiumServicing` is already the widest surface in
	// the package. Each is one line: the validation, the traces and the inactive-layer behaviour all
	// belong to the layer, and a copy of any of them here would drift from it at the first edit.

	/// Writes one custom attribute to the Adapty profile — the app's own, such as the place a
	/// purchase was made from. The keys the package writes itself (`lastUsedDay`, `launchSession`,
	/// `deep_link_value`) do not need to be passed in.
	///
	/// A pair Adapty would refuse — a key outside 1…30 characters of `A-Za-z0-9._-`, a value outside
	/// 1…50 characters — is not sent, and the reason lands in ``configurationIssues`` instead of the
	/// attribute quietly disappearing.
	public func setProfileValue(value: String, key: String) {
		adapty.setProfileValue(value: value, key: key)
	}

	/// Did nothing since 0.3.0, and does nothing now.
	///
	/// It used to report one onboarding screen to Adapty as `onboarding_<step>`, through
	/// `logShowOnboarding(name:screenName:screenOrder:)`. Adapty 4.x deleted that call: onboardings
	/// are a rendered flow of their own there, fetched with `getOnboarding` and reported by the view
	/// that draws them — there is no longer any way to report a screen the app drew itself, and the
	/// package does not draw screens.
	///
	/// Kept as a deprecated no-op rather than removed so an app on 0.2.x still builds against 0.3.0
	/// and gets a warning at the call site instead of an error. It will be deleted in a later
	/// release; delete the call. Onboarding funnels belong in Amplitude — `analytics.log(_:)` — which
	/// is where every other screen event in an app using this package already goes.
	@available(*, deprecated, message: "Adapty 4.x removed onboarding reporting; log onboarding steps through analytics instead. This call does nothing.")
	public func logOnboardingOpen(step: Int) {}

	/// AF-04 row 2: how many times AppsFlyer answered "deep link found" and handed over nothing.
	/// A deep link the campaign was paid for disappears each time, and the only other trace is a
	/// `debugLog` line no shipping build prints. Zero without AppsFlyer — there are no deep links
	/// to drop. Not a `configurationIssues` entry: nothing here is misconfigured, so a list meant
	/// for causes no retry will fix would fill up with weather.
	public var droppedDeepLinks: Int {
		appsFlyer?.droppedDeepLinks ?? 0
	}

	/// Everything the package could not make work and no retry will fix — an empty key, a device id
	/// that arrived too late, a Firebase that was never configured, a placement the dashboard does
	/// not have. One line per cause, oldest first. Empty is the healthy state.
	///
	/// The same list `premium.configurationIssues` answers: it is the package's, not the premium
	/// layer's, and the causes it collects come from every service.
	public var configurationIssues: [String] {
		ConfigurationIssues.shared.all
	}
}
