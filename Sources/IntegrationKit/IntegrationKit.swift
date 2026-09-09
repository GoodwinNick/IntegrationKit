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

public struct IntegrationKit {
	public let premium: PremiumServicing
	public let analytics: AnalyticsTracking
	public let crashes: CrashReporting

	// Kept only to stay alive and to back the forwards below — never handed out. AppsFlyer is
	// optional because an app without a dev key simply has no attribution.
	private let adapty: AdaptyServicing
	private let appsFlyer: AppsFlyerServicing?
	/// Keeps the `didBecomeActive` paywall-retry observer alive: `NotificationCenter` does not
	/// retain the token the block-based API hands back, so dropping this would silently stop the
	/// retries after the first launch.
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
		attTimeout: TimeInterval = 60
	) -> IntegrationKit {
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
			isTestsRunning: isTestsRunning
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

		return IntegrationKit(
			premium: premium,
			analytics: analytics,
			crashes: CrashReporter(),
			adapty: adapty,
			appsFlyer: appsFlyer,
			adaptyRefreshObserver: adaptyRefreshObserver
		)
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
