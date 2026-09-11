//
//  IntegrationKit.swift
//  IntegrationKit
//
//  Composition root. Spec 3.5: exactly four protocols are public — `PremiumServicing`,
//  `AnalyticsTracking`, `CrashReporting`, `RemoteConfigServicing`. Adapty and AppsFlyer are internal, so the app can no
//  longer wire the services itself (a public initializer cannot take an internal type). This
//  builds them instead, in the one order that works: Amplitude first, because Adapty links its
//  own profile to the Amplitude device id, then Adapty, then AppsFlyer, which pushes attribution
//  into both. Firebase stays a separate `FirebaseIntegration.configure()` — it holds nothing.
//

import AppTrackingTransparency
import Foundation
import UIKit

/// Everything the app is given, in one value: the four protocols, the `AppDelegate` forwards and
/// the package's own diagnostics. Build it once with ``configure(deviceId:amplitudeKey:adaptyKey:placements:sessionsCounter:sharedSecret:productIds:isDebug:isTestsRunning:levels:firstOpenEvent:appsFlyerDevKey:appsFlyerAppId:sourceTimeout:attTimeout:adaptyAttributionEnabled:remoteConfigDefaults:remoteConfigTimeout:)``
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
	/// The remote-config layer: values by the app's own keys, defaults until the fetch lands.
	public let remoteConfig: RemoteConfigServicing

	// Kept only to stay alive and to back the forwards below — never handed out. AppsFlyer is
	// optional because an app without a dev key simply has no attribution.
	private let adapty: AdaptyServicing
	private let appsFlyer: AppsFlyerServicing?
	/// The `didBecomeActive` token — paywall retry, plus the premium barrier while the question is
	/// still open. Holding it is not what keeps the observation alive — `NotificationCenter` retains
	/// the block-based observer itself, whether or not anyone keeps the token, and the block retains
	/// the Adapty layer with it. It is kept because it is the only handle that could ever remove the
	/// observation, and a struct has no `deinit` to do that from: the observation lasts the process,
	/// by construction.
	private let foregroundObserver: NSObjectProtocol

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
	/// `remoteConfigDefaults` are the app's own Firebase Remote Config keys and the value each one
	/// answers until the fetch lands — `["paywallReview": NSNumber(value: false)]`. The package names
	/// no key of its own: an empty dictionary means the app does not use remote config, and every
	/// read would answer the type's zero, so it is recorded in ``configurationIssues`` and no fetch
	/// is made. `remoteConfigTimeout` is how long that fetch waits. Five seconds is a number from
	/// practice — comfortably inside a splash plus the taps it takes to reach a paywall — and an app
	/// that shows a remote-driven screen sooner passes its own.
	///
	/// `launchOptions` is the dictionary `application(_:didFinishLaunchingWithOptions:)` was handed.
	/// Pass it through: a cold launch that came from a Universal Link carries the link in there, and
	/// AppsFlyer holds the first session back until that link resolves only if it is given it. Left
	/// out, the session is sent before the link is known and the install is attributed without it.
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
		adaptyAttributionEnabled: Bool = false,
		remoteConfigDefaults: [String: NSObject] = [:],
		remoteConfigTimeout: TimeInterval = 5,
		launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
	) -> IntegrationKit {
		// No key is ever printed — they are credentials, and every branch below reads only whether one
		// is there. The tag is left off on purpose: these lines belong to the graph, not to a service,
		// so they come out as plain `[IntegrationKit]`.
		debugLog("configure: deviceId \(deviceId), isDebug \(isDebug), isTestsRunning \(isTestsRunning)")
		debugLog("configure: keys — amplitude \(amplitudeKey.isEmpty ? "empty" : "set"), adapty \(adaptyKey.isEmpty ? "empty" : "set"), appsFlyer \(appsFlyerDevKey.isEmpty ? "empty" : "set"), sharedSecret \(sharedSecret.isEmpty ? "empty — receipt validation off" : "set")")
		debugLog("configure: levels \(levels.sorted()), placements \(placements), productIds \(productIds.sorted()), sessionsCounter \(sessionsCounter)")
		debugLog("configure: sourceTimeout \(sourceTimeout)s, attTimeout \(attTimeout)s, remoteConfigTimeout \(remoteConfigTimeout)s, remoteConfigDefaults \(remoteConfigDefaults.keys.sorted()), adaptyAttributionEnabled \(adaptyAttributionEnabled), firstOpenEvent \(firstOpenEvent ?? "none")")
		if let built {
			debugLog(level: .error, "configure called a second time — the kit from the first call is returned and these arguments are ignored")
			ConfigurationIssues.shared.record(
				"IntegrationKit.configure was called more than once — the kit built by the first call is returned and these arguments are ignored",
				tag: Self.tag
			)
			return built
		}
		// TM-01: the one decision the test-mode layer makes, taken here and nowhere else. Every fake
		// source in the package hangs off this single branch, and there is no other entrance to any of
		// them — outside a launch the app itself called a test launch, `ProcessInfo` is not read at
		// all. `#if DEBUG` would be the wrong guard and not a stricter one: the package arrives as a
		// release dependency while the app's own test build is Debug, so it would remove the layer
		// exactly where it is needed and leave it where it is not (TM-01 row 4).
		let testMode: TestModeGraph? = isTestsRunning
			? TestModeGraph.make(
				arguments: ProcessInfo.processInfo.arguments,
				environment: ProcessInfo.processInfo.environment,
				levels: levels,
				productIds: productIds,
				remoteConfigDefaults: remoteConfigDefaults
			)
			: nil
		debugLog(testMode == nil ? "test mode off — every layer is the real one" : "test mode ON — fake sources replace Adapty, Apple, analytics and remote config")

		// First of the four, and the only one that is not a network dependency of the others: a
		// paywall variant is read on the way to the first screen, so the fetch gets whatever head
		// start the rest of this method takes.
		let remoteConfig: RemoteConfigServicing
		if let testMode {
			remoteConfig = testMode.remoteConfig
			debugLog("remote config: fake, values come from the launch flags")
		} else {
			let service = RemoteConfigService(defaults: remoteConfigDefaults)
			service.configure(timeout: remoteConfigTimeout, isDebug: isDebug, isTestsRunning: isTestsRunning)
			remoteConfig = service
			debugLog("remote config: real, \(remoteConfigDefaults.count) default(s), fetch waits up to \(remoteConfigTimeout)s")
		}

		// TM-07: Amplitude is not built at all in a test run — the sink replaces the sending, not the
		// SDK, so there is nothing left that could reach the live dashboard.
		let analytics: AnalyticsTracking
		if let testMode {
			analytics = testMode.analytics
			debugLog("analytics: sink only — Amplitude is not built at all in a test run")
		} else {
			let amplitude = AmplitudeAnalytics(isDebug: isDebug)
			amplitude.configure(apiKey: amplitudeKey, deviceId: deviceId, firstOpenEvent: firstOpenEvent, isTestsRunning: isTestsRunning)
			analytics = amplitude
			debugLog("analytics: Amplitude configured")
		}

		// Both protocols, because this one value fills both seats: `PremiumService` needs the premium
		// source, the facade and AppsFlyer need the app-facing surface. The fake implements the same
		// two, which is what keeps the arbiter above it the production one (TM-03).
		let adapty: any AdaptyServicing & AdaptyPremiumProviding
		if let testMode {
			adapty = testMode.adapty
			debugLog("adapty: fake source — the arbiter above it stays the production one")
		} else {
			let service = AdaptyService()
			service.configure(
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
			adapty = service
			debugLog("adapty: real service configured, attribution service \(adaptyAttributionEnabled ? "on" : "off")")
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
				isTestsRunning: isTestsRunning,
				launchOptions: launchOptions
			)
			appsFlyer = service
			debugLog("appsFlyer: layer built")
		} else {
			debugLog(level: .error, "appsFlyer: no dev key — the layer is not built at all, and the AppDelegate forwards will be no-ops")
			// AF-01 row 1. The service records this itself, but only a service that was built — and
			// an empty dev key is exactly the case where none is. Written here so the forgotten key
			// has a reason in the one list the guide tells an integrator to read, with the same text
			// the service would have used, so the two can never read as different causes.
			ConfigurationIssues.shared.record(
				"AppsFlyer got an empty dev key — attribution and deep links are off for this run",
				tag: "AppsFlyer"
			)
		}

		// TM-04/TM-05: a test run does not touch StoreKit at all — no payment queue, no receipt
		// validation, no system dialog that could stop a run dead (TM-04 row 5).
		let apple: AppleSubscribing
		let storeKit: StoreKitService?
		if let testMode {
			apple = testMode.apple
			storeKit = nil
			debugLog("storeKit: not built — a test run touches no payment queue and validates no receipt")
		} else {
			let service = StoreKitService(sharedSecret: sharedSecret, productIds: productIds)
			apple = service
			storeKit = service
			debugLog("storeKit: real service, \(productIds.count) product id(s) to look for in the receipt")
		}
		// `productIds` has to reach here too, not just StoreKit: it is the fallback list `products`
		// prices directly when Adapty's own listing for a placement comes back empty, and an empty
		// list would leave an unloaded paywall with no prices at all.
		let premium = PremiumService(
			// The store is handed over rather than defaulted so that a test run can wipe the previous
			// run's verdict through the same object, before anything reads it (TM-03 row 7).
			store: testMode?.store ?? UserDefaultsPremiumStore(),
			adapty: adapty,
			apple: apple,
			levels: levels,
			sourceTimeout: sourceTimeout,
			productIds: productIds
		)
		// Started here on purpose: the seed-cache-then-refresh step is not a decision the app
		// gets to make differently, and a composition root that leaves it to be forgotten is
		// the defect this rewrite exists to remove.
		debugLog("premium: service built, store \(testMode == nil ? "UserDefaults" : "test-mode store"), starting it now")
		premium.start()
		debugLog("premium: started — cache published, sources asked")
		// The same argument, one level down: a purchase interrupted mid-flight is delivered by
		// the payment queue, not by any call above, and it stays stuck in that queue until it is
		// finished. Re-asking afterwards is what turns it into premium in this launch instead of
		// the next one.
		storeKit?.completeTransactions { [weak premium] in
			debugLog("payment queue delivered an interrupted purchase — re-asking the barrier")
			premium?.purchaseDelivered()
		}
		if testMode?.flags.pendingTransaction == true {
			debugLog("test mode: a pending transaction was seeded — delivering it as the payment queue would")
			// TM-04: one unfinished transaction was already in the queue at launch. It reaches the
			// arbiter as a delivered purchase, exactly as the real payment queue would deliver it, and
			// PM-08 decides what it means — the flag does not turn premium on by itself (TM-04 row 4).
			premium.purchaseDelivered()
		}
		// Two retries on one notification, for the same reason: a cold start is where a flaky network
		// costs the most. Adapty's own paywall fetch can lose that race (cold CDN), so every placement
		// still missing is asked for again — and PM-02 row 7, if no source answered about premium
		// either, the whole barrier runs again. The premium half is conditional: once Adapty has
		// answered for real, the profile push keeps the verdict fresh and re-asking buys nothing.
		let foregroundObserver = NotificationCenter.default.addObserver(
			forName: UIApplication.didBecomeActiveNotification,
			object: nil,
			queue: .main
		) { [weak premium] _ in
			debugLog("foreground: re-asking for the paywalls that are still missing, and for premium if the question is still open")
			adapty.refreshPaywalls()
			premium?.refreshIfUnanswered()
		}
		debugLog("foreground observer installed")

		let kit = IntegrationKit(
			premium: premium,
			analytics: analytics,
			crashes: CrashReporter(),
			remoteConfig: remoteConfig,
			adapty: adapty,
			appsFlyer: appsFlyer,
			foregroundObserver: foregroundObserver
		)
		built = kit
		debugLog("configure done — the kit is ready, \(ConfigurationIssues.shared.all.count) configuration issue(s) so far")
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
		debugLog("handleContinue: \(userActivity.activityType)")
		guard let appsFlyer else {
			debugLog("handleContinue: no AppsFlyer layer was ever built — answering the system with nothing, once")
			restorationHandler(nil)
			return
		}
		appsFlyer.handleContinue(userActivity, restorationHandler: restorationHandler)
	}

	/// Forwards `application(_:open:options:)`.
	public func handleOpen(_ url: URL, options: [UIApplication.OpenURLOptionsKey: Any]) {
		debugLog("handleOpen: \(url.absoluteString)\(appsFlyer == nil ? " — no AppsFlyer layer, nothing to forward to" : "")")
		appsFlyer?.handleOpen(url, options: options)
	}

	/// Forwards the pre-iOS 9 `application(_:open:sourceApplication:annotation:)`.
	///
	/// The system still calls that one, and the SDK keeps a separate entry point for it, so an app
	/// that implements only the `options:` variant drops those opens without a trace. Implement both
	/// in AppDelegate and hand both to the kit:
	///
	/// ```swift
	/// func application(_ application: UIApplication, open url: URL, sourceApplication: String?, annotation: Any) -> Bool {
	///     kit.handleOpen(url, sourceApplication: sourceApplication, annotation: annotation)
	///     return true
	/// }
	/// ```
	public func handleOpen(_ url: URL, sourceApplication: String?, annotation: Any?) {
		debugLog("handleOpen (legacy): \(url.absoluteString), sourceApplication \(sourceApplication ?? "none")\(appsFlyer == nil ? " — no AppsFlyer layer, nothing to forward to" : "")")
		appsFlyer?.handleOpen(url, sourceApplication: sourceApplication, annotation: annotation)
	}

	/// The ATT answer reaches all three SDKs that cannot read it themselves. Adapty's half would be
	/// unreachable otherwise, now that the app cannot hold an `AdaptyServicing`.
	///
	/// **Call this as soon as the prompt is answered, whatever the answer.** Since SDK 7.0 AppsFlyer
	/// no longer waits for ATT on its own, so this package holds the first session until this call —
	/// or until `attTimeout` runs out. An app that never makes it spends that whole timeout and then
	/// sends the install with no IDFA, which is an attribution that reads as organic.
	public func updateTrackingAuthorization(_ status: ATTrackingManager.AuthorizationStatus) {
		debugLog("ATT answer \(status.rawValue) forwarded to Amplitude, Adapty and AppsFlyer")
		analytics.updateTrackingAuthorization(status)
		adapty.updateAppTrackingTransparencyStatus(status)
		appsFlyer?.updateTrackingAuthorization(status)
	}

	/// One fact about this user, written to both dashboards at once — the Adapty profile and the
	/// Amplitude user profile. For the app's own facts that both sides get asked about: a cohort, a
	/// plan name, a counter of things generated.
	///
	/// The two single-SDK routes stay available and are not deprecated by this one:
	/// ``setProfileValue(value:key:)`` writes to Adapty alone, and
	/// ``AnalyticsTracking/setUserProperties(_:)`` on ``analytics`` writes to Amplitude alone, in
	/// bulk and with values of any type.
	///
	/// The two halves are independent on purpose. A pair Adapty refuses — its keys are 1…30
	/// characters of `A-Za-z0-9._-`, its values 1…50 — still reaches Amplitude, which has no such
	/// limit; the refusal lands in ``configurationIssues`` as it always does. Letting the stricter
	/// SDK veto the other one would silently drop analytics data over a rule that is not analytics'.
	public func setUserProperty(value: String, key: String) {
		debugLog("setUserProperty \(key) = \(value) — to the Adapty profile and the Amplitude profile both")
		adapty.setProfileValue(value: value, key: key)
		analytics.setUserProperties([key: value])
	}

	// MARK: - Adapty forwards.
	// Identity, in and out. Everything here is input only the app has, or an answer only the app
	// wants, and none of it belongs on a premium protocol — a profile attribute is not a purchase,
	// and `PremiumServicing` is already the widest surface in the package. Each is one line: the
	// validation, the traces and the inactive-layer behaviour all belong to the layer, and a copy of
	// any of them here would drift from it at the first edit.

	/// Writes one custom attribute to the Adapty profile — the app's own, such as the place a
	/// purchase was made from. The keys the package writes itself (`lastUsedDay`, `launchSession`,
	/// `deep_link_value`) do not need to be passed in.
	///
	/// A pair Adapty would refuse — a key outside 1…30 characters of `A-Za-z0-9._-`, a value outside
	/// 1…50 characters — is not sent, and the reason lands in ``configurationIssues`` instead of the
	/// attribute quietly disappearing.
	public func setProfileValue(value: String, key: String) {
		debugLog("setProfileValue \(key) = \(value) — Adapty only")
		adapty.setProfileValue(value: value, key: key)
	}

	/// The Adapty profile's own id — what an app sends to its own backend to describe the same user
	/// on both sides.
	///
	/// `nil` means Adapty did not answer: the layer is off, or the profile has not been created yet,
	/// or the call ran out of time. It never means "this user has no id". Ask again later in the same
	/// run rather than storing the `nil`, which would turn a slow start into a permanent absence.
	public func adaptyProfileId() async -> String? {
		let id = await adapty.profileId()
		debugLog("adaptyProfileId: \(id ?? "nil — Adapty did not answer, this is not \"no id\"")")
		return id
	}

	/// Links Firebase's id for this install to the Adapty profile, so a purchase in one dashboard can
	/// be found in the other. Pass `Analytics.appInstanceID()` — the package does not read it itself,
	/// because reaching into another SDK for its own identifier is the app's call, not a library's.
	///
	/// Call it whenever the id is in hand, including before the layer has finished starting: a write
	/// that arrives early waits for activation instead of being dropped. An empty string is refused
	/// and the reason lands in ``configurationIssues`` — `Analytics.appInstanceID()` answers `nil`
	/// while Firebase analytics is still coming up, and passing that through as `""` would put a join
	/// key on the profile that matches nothing.
	public func setFirebaseAppInstanceId(_ id: String) {
		debugLog("setFirebaseAppInstanceId: \(id.isEmpty ? "empty — refused, Firebase analytics has not come up yet" : id)")
		adapty.setFirebaseAppInstanceId(id)
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
	public func logOnboardingOpen(step: Int) {
		debugLog(level: .error, "logOnboardingOpen(step: \(step)) does nothing since 0.3.0 — Adapty 4.x removed onboarding reporting; log the step through analytics instead")
	}

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
