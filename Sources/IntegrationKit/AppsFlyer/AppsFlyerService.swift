//
//  AppsFlyerService.swift
//  IntegrationKit
//
//  AppsFlyer attribution — feeds analytics events and links the AppsFlyer identity to Adapty.
//  No custom backend involved: everything stays inside AnalyticsTracking/AdaptyServicing.
//

import AppTrackingTransparency
import AppsFlyerLib
import Foundation
import Security
import UIKit

final class AppsFlyerService: NSObject, AppsFlyerServicing {

	private static let tag = "AppsFlyer"

	private let analytics: AnalyticsTracking
	private let adapty: AdaptyServicing

	/// Internal (not private) so unit tests can seed/observe it without going through the real
	/// `AppsFlyerLib.shared().start()` network call. It no longer gates anything — AF-02 row 1: a
	/// session belongs to every foreground return, and near-identical starts are deduplicated by the
	/// SDK's own `minTimeBetweenSessions` (5 s), not by a flag of ours.
	var didStartAppsFlyer = false

	/// AF-01 row 5. Set only by a `configure` that actually stood the SDK up, so an empty dev key
	/// leaves it false and every forward below stays a no-op.
	private var isConfigured = false

	/// AF-04 row 2. How many times the SDK said "deep link found" and handed over nothing. Not a
	/// configuration issue — nothing is misconfigured, the SDK contradicted itself — so it is
	/// counted rather than filed as a cause.
	private(set) var droppedDeepLinks = 0

	/// AF-01 row 2. The limit the app named, kept because the wait it limits is ours now. Until 7.0
	/// the SDK held the install data for the ATT answer itself; its own header deprecates that with
	/// "the SDK no longer manages ATT timing internally", and says in the same file that ATT is not a
	/// session-readiness condition either. The parameter means what it always meant — how long to wait
	/// before giving up on the answer — only the waiting moved in here.
	private var attTimeout: TimeInterval = 0

	/// Whether the app has reported the ATT answer. Any answer settles the question: what the session
	/// is waiting for is the dialog being over, not a particular verdict.
	private var isTrackingAnswered = false

	/// Whether a session is sitting here waiting for that answer. Separate from `isTrackingAnswered`
	/// because "nobody asked yet" and "asked and held" behave differently on the next foreground
	/// cycle — the second must not queue a second hold.
	private var isSessionHeldForTracking = false

	init(analytics: AnalyticsTracking, adapty: AdaptyServicing) {
		self.analytics = analytics
		self.adapty = adapty
		super.init()
	}

	deinit {
		// AF-01 row 4 is gone along with the mechanism it was about: there is no `NotificationCenter`
		// subscription any more, so nothing can outlive this object holding it. The SDK's readiness
		// listener captures the service weakly, so one that survives it does nothing at all rather
		// than resurrecting it — and it is not unregistered here on purpose, because the listener on
		// the SDK's process-wide singleton may already belong to a newer service.
		debugLog(tag: Self.tag, "deinit — the session-ready listener that captured this service is now inert")
	}

	/// The two Keychain accounts AppsFlyer's Reinstall Detection writes. The names are in no header —
	/// they were read out of the 7.0.2 binary, next to `migrateRICounterKeychainData` and
	/// `migrateRIKeychainData`, which are the functions that put them there. Keychain rows outlive the
	/// app bundle, so these two are the entire reason a reinstall is reported as a reinstall: every
	/// other thing the SDK remembers about the install dies with the container.
	private static let reinstallDetectionAccounts = ["KCAppsFlyerRICounter", "KCAppsFlyerLastInstallDate"]

	/// Whether this build can only be talking to Apple's sandbox — which, for what this decides, means
	/// "did not come from the App Store". The embedded provisioning profile is the signal: Apple
	/// strips it when it re-signs a build for the store, so a run from Xcode and a TestFlight build
	/// both carry one and a store build never does. A simulator carries none either, and is answered
	/// before the lookup for exactly that reason.
	///
	/// The receipt file name would answer the same question and is the better-known way to ask it, but
	/// `appStoreReceiptURL` is deprecated as of iOS 18 in favour of an async StoreKit call, and this
	/// has to answer synchronously on the way into `configure`.
	///
	/// Read positively, not as "anything that is not production". An unanticipated case then reads as
	/// production and the wipe does not happen, which is the failure worth having: a launch that keeps
	/// its reinstall counter is a debugging nuisance, a launch that invents an install in a dashboard
	/// shared with real money is not.
	private static var isSandboxBuild: Bool {
		#if targetEnvironment(simulator)
			return true
		#else
			return Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision") != nil
		#endif
	}

	/// The rule for whether a launch wipes the install state before standing the SDK up, kept apart
	/// from the launch that applies it so a check can put every combination through it. It is not
	/// readable from the live wiring: a command-line check runs on macOS, where the receipt carries
	/// the production name and the true branch would be unreachable.
	///
	/// All three have to hold. `isDebug` is the app's own `#if DEBUG` — the only build configuration a
	/// package ever gets to see, since it is compiled apart from the app. The provisioning profile
	/// rules out a build that came from the store. And the switch exists because an app that wants its
	/// debug runs to keep counting reinstalls has to be able to say so. TestFlight carries a profile
	/// too, and is kept out by `isDebug`, which a release build answers false to.
	static func shouldResetInstallState(isEnabled: Bool, isDebug: Bool, isSandboxBuild: Bool) -> Bool {
		isEnabled && isDebug && isSandboxBuild
	}

	/// What a Keychain row holds, rendered for a log line. AppsFlyer writes these as text, so the UTF-8
	/// reading is the expected one; the two fallbacks exist because a row written by a version that
	/// stored something else must still print as something a reader can act on, rather than crash the
	/// reset or silently read as empty.
	private static func keychainValue(matching query: [String: Any]) -> String {
		var query = query
		query[kSecReturnData as String] = true
		query[kSecMatchLimit as String] = kSecMatchLimitOne
		var found: CFTypeRef?
		let status = SecItemCopyMatching(query as CFDictionary, &found)
		guard status == errSecSuccess, let data = found as? Data else {
			return "unreadable (OSStatus \(status))"
		}
		return String(data: data, encoding: .utf8) ?? "\(data.count) bytes, not text"
	}

	/// Makes the next launch look like a first install to AppsFlyer. Debug builds only, by contract.
	///
	/// An install attributes once per device and not twice: the second one and every one after it come
	/// back `af_status: Organic` with no deferred deep link, because the SDK reports a reinstall and
	/// the server does not re-attribute those inside the re-attribution window. Erasing the simulator
	/// is the other way back to a clean device, and it is the reason this exists — that erase costs a
	/// reinstall of everything on the device, to clear what is two Keychain rows and a set of defaults.
	///
	/// There is no build-configuration guard in here on purpose: a package is compiled apart from the
	/// app and cannot read the app's. The caller gates it, and every run is filed in
	/// ``IntegrationKit/configurationIssues`` — so a release build that somehow reaches this says so
	/// out loud, instead of quietly filing invented installs into a dashboard shared with production.
	///
	/// Must run before `configure`: the SDK reads both stores while it is being stood up.
	static func resetInstallState() {
		let defaults = UserDefaults.standard
		// Dropped by prefix rather than from a list of names. The SDK adds keys between versions and a
		// hardcoded list would go stale without saying so — and one surviving key is enough to keep
		// `isFirstLaunch` false, which is the single thing this is for.
		let dropped = defaults.dictionaryRepresentation()
			.filter { $0.key.hasPrefix("AppsFlyer") }
			.sorted { $0.key < $1.key }
		for (key, value) in dropped {
			// Every value is printed on its way out, because the values are the diagnosis.
			// `AppsFlyerReInstallCounter = 3` is the whole explanation of an organic verdict — it says
			// the server has been told about this device three times before — and "18 keys dropped"
			// explains nothing at all. The cap is for `AppsFlyerConversiondataKey`, which is a keyed
			// archive and stays unreadable at any length.
			debugLog(tag: Self.tag, "dropping \(key) = \(String(describing: value).prefix(200))")
			defaults.removeObject(forKey: key)
		}

		var removed: [String] = []
		var failed: [String] = []
		for account in Self.reinstallDetectionAccounts {
			// Matched by account alone. The service name is derived from the bundle id at runtime, and
			// these account names belong to nobody else, so narrowing further would only add a way to
			// miss the row. The app's own access group is implied — nothing outside this app is
			// reachable from here even if the query were wrong.
			let query: [String: Any] = [
				kSecClass as String: kSecClassGenericPassword,
				kSecAttrAccount as String: account
			]
			// Read before the delete, or there is nothing left to read. This row is the one place the
			// counter exists on the launch right after a reinstall — `AppsFlyerReInstallCounter` in the
			// defaults above only holds it once the SDK has migrated it across, and a migration that
			// failed is exactly the case worth seeing in a log.
			let value = Self.keychainValue(matching: query)
			switch SecItemDelete(query as CFDictionary) {
				case errSecSuccess:
					debugLog(tag: Self.tag, "dropping Keychain \(account) = \(value)")
					removed.append(account)
				case errSecItemNotFound:
					debugLog(tag: Self.tag, "Keychain \(account) — nothing stored under it, this device had not been seen before")
				case let status:
					failed.append("\(account) (OSStatus \(status))")
			}
		}
		debugLog(tag: Self.tag, "install state reset — \(dropped.count) UserDefaults keys dropped, Keychain rows removed: \(removed.isEmpty ? "none" : removed.joined(separator: ", "))")
		if !failed.isEmpty {
			debugLog(tag: Self.tag, level: .error, "Keychain rows that would not delete: \(failed.joined(separator: ", ")) — this launch is still going to be reported as a reinstall")
		}
		ConfigurationIssues.shared.record(
			"AppsFlyer install state was wiped before configure — this launch reports a fresh install. Debug-only: a release build must never reach it",
			tag: Self.tag
		)
	}

	/// `isTestsRunning` and `launchOptions` default only so the checks' own call sites stay short —
	/// the composition root always passes the app's answers, and the app always computes them.
	func configure(devKey: String, appId: String, deviceId: String, attTimeout: TimeInterval, isDebug: Bool, isTestsRunning: Bool = false, resetsInstallInSandbox: Bool = false, launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) {
		// The dev key itself never reaches the log — it is a credential, and "set"/"empty" is the
		// only thing about it any of the branches below actually reads.
		debugLog(tag: Self.tag, "configure: devKey \(devKey.isEmpty ? "empty" : "set"), appId \(appId), deviceId \(deviceId), attTimeout \(attTimeout)s, isDebug \(isDebug), isTestsRunning \(isTestsRunning), resetsInstallInSandbox \(resetsInstallInSandbox)")
		// AF-01 row 1, the second of the two switches: a test run must not stand the SDK up at all.
		// Attribution is bought traffic — sessions and install data from a robot move the numbers
		// an advertising budget is steered by. Its own reason, apart from the empty dev key: that
		// one is an app shipping without attribution, this one is a key that is perfectly fine.
		guard !isTestsRunning else {
			debugLog(tag: Self.tag, "configure stopped: the app reported a test run — the SDK is not stood up at all")
			ConfigurationIssues.shared.record(
				"AppsFlyer is off for this run — the app reported a test run",
				tag: Self.tag
			)
			return
		}
		// AF-01 row 1: a supported way to run without attribution — a test build, a flavour without
		// AppsFlyer — but not a silent one. Without this line "no attribution" and "forgot the key"
		// look identical from a release build.
		guard !devKey.isEmpty else {
			debugLog(tag: Self.tag, level: .error, "configure stopped: empty dev key — attribution and deep links are off for this run")
			ConfigurationIssues.shared.record(
				"AppsFlyer got an empty dev key — attribution and deep links are off for this run",
				tag: Self.tag
			)
			return
		}
		// AF-01 row 5: a second entry point in the app would otherwise stand the SDK up again and
		// register a second foreground observer, so one return would run the handler twice.
		guard !isConfigured else {
			debugLog(tag: Self.tag, "configure ignored: already configured in this process")
			return
		}
		isConfigured = true
		self.attTimeout = attTimeout

		// Ahead of `initialize`, because that is where the SDK reads both stores. Afterwards the wipe
		// clears rows the SDK is already holding in memory, and the launch is reported as a reinstall
		// anyway — the state would come back on the next launch, having helped with nothing.
		if Self.shouldResetInstallState(isEnabled: resetsInstallInSandbox, isDebug: isDebug, isSandboxBuild: Self.isSandboxBuild) {
			debugLog(tag: Self.tag, "debug build on a sandbox device — wiping the install state so this launch is attributed as a first install")
			Self.resetInstallState()
		} else {
			// Logged on the way past, because "the link did not come back" and "the wipe did not run"
			// are the same sentence to whoever is looking, and the three values say which one it was.
			debugLog(tag: Self.tag, "install state kept — resetsInstallInSandbox \(resetsInstallInSandbox), isDebug \(isDebug), sandbox build \(Self.isSandboxBuild). This device has been seen before, so the install goes out as a reinstall and carries no deferred link")
		}

		AppsFlyerLib.shared().initialize(devKey: devKey, appId: appId)
		debugLog(tag: Self.tag, "SDK initialized for appId \(appId)")
		// Documented to be needed on every launch, and to be useless after `start` — set here, ahead
		// of the observer below, so a foreground signal physically cannot overtake it.
		AppsFlyerLib.shared().customerUserID = deviceId
		debugLog(tag: Self.tag, "customerUserID set to \(deviceId) — before start, as the SDK requires")
		AppsFlyerLib.shared().delegate = self
		AppsFlyerLib.shared().deepLinkDelegate = self
		debugLog(tag: Self.tag, "delegate and deepLinkDelegate wired to the service")
		// AF-01 row 3: the app's flag, not the build configuration. A package cannot know whether
		// this build wants SDK logs; leaving it hardwired means nobody can turn them on to check an
		// integration, or off in a debug build that ships.
		AppsFlyerLib.shared().isDebug = isDebug
		debugLog(tag: Self.tag, "SDK console logging \(isDebug ? "on" : "off") — the app's own key")

		// AF-05: a cold launch that arrived through a Universal Link carries it in `launchOptions`,
		// and the SDK only learns about it if it is handed over here — before the listener below.
		// With it, session readiness waits for that link to resolve; without it the session goes out
		// first and the link lands after the install was already attributed to nobody. A no-op when
		// there is no link in there.
		AppsFlyerLib.shared().handleLaunchOptions(launchOptions)
		// The dictionary is printed, not just counted. "Something was in there" is the one thing that
		// cannot answer "why did the link not arrive" — the answer is which key and which URL, and a
		// log that withholds it sends the reader back to the AppDelegate to guess.
		if let launchOptions {
			debugLog(tag: Self.tag, "launch options handed to the SDK — \(launchOptions). A link in there now holds the session until it resolves")
		} else {
			debugLog(tag: Self.tag, "launch options handed to the SDK — the app passed none. Either this was an ordinary launch, or the app is not forwarding its AppDelegate dictionary to IntegrationKit.configure(launchOptions:) — in which case a cold launch from a link is lost before anything here can see it")
		}
		// AF-02 row 1: the session is started from the SDK's own readiness listener, never from
		// `didBecomeActiveNotification`. `AppsFlyerLib.start` says so in as many words — "call this
		// inside a registerSessionReadyListener: block, not directly in applicationDidBecomeActive:"
		// — and that listener is what waits for the deep link to resolve first. The cadence is
		// unchanged: it fires once per foreground cycle and resets on background, so every return to
		// the foreground still gets its session.
		AppsFlyerLib.shared().registerSessionReadyListener { [weak self] in
			self?.startAppsFlyer()
		}
		debugLog(tag: Self.tag, "configure done — the SDK's session-ready listener now drives every session")
	}

	func handleContinue(_ userActivity: NSUserActivity, restorationHandler: @escaping ([UIUserActivityRestoring]?) -> Void) {
		debugLog(tag: Self.tag, "continue: activityType \(userActivity.activityType), webpageURL \(userActivity.webpageURL?.absoluteString ?? "none")")
		// AF-05 row 1: the system asked, and it must get exactly one answer — an app that never
		// answers sits on its launch screen. There is no guarantee anywhere that the SDK calls its
		// block, and AppsFlyer's own example passes `nil` for it, so the answer cannot be left to
		// live inside that block alone.
		var answered = false
		let answer: ([UIUserActivityRestoring]?) -> Void = { restoring in
			guard !answered else {
				debugLog(tag: Self.tag, "continue: a second answer arrived and was dropped — the system already got one")
				return
			}
			answered = true
			debugLog(tag: Self.tag, "continue: answering the system with \(restoring?.count ?? 0) object(s)")
			restorationHandler(restoring)
		}

		guard isConfigured else {
			// AF-05 row 3: nothing was initialized, so there is nothing to forward to — but the
			// system still gets its answer. The reason is already in `configurationIssues`, recorded
			// once when the empty key arrived.
			debugLog(tag: Self.tag, "continue: the layer is off — nothing goes to the SDK, the system still gets an empty answer")
			answer(nil)
			return
		}

		AppsFlyerLib.shared().continue(userActivity) { restoring in
			debugLog(tag: Self.tag, "continue: the SDK answered with \(restoring?.count ?? 0) raw object(s)")
			// AF-05 row 2: element by element. Casting the array as a whole turns one foreign object
			// into a `nil` answer and loses every good object with it.
			answer(restoring?.compactMap { $0 as? UIUserActivityRestoring })
		}
		if !answered {
			debugLog(tag: Self.tag, "continue: the SDK did not answer in time — falling back to an empty answer")
		}
		// The SDK answered synchronously or not at all: the restoration handler is UIKit's, and a
		// late answer is no better than none. Whatever `continue` did not deliver by now is empty.
		answer(nil)
	}

	func handleOpen(_ url: URL, options: [UIApplication.OpenURLOptionsKey: Any]) {
		debugLog(tag: Self.tag, "open: \(url.absoluteString), options \(options.keys.map(\.rawValue).sorted())")
		guard isConfigured else {
			debugLog(tag: Self.tag, "open: the layer is off — the URL does not reach the SDK")
			return
		}
		AppsFlyerLib.shared().handleOpen(url, options: options)
		debugLog(tag: Self.tag, "open: forwarded to the SDK unchanged")
	}

	/// AF-05: the pre-iOS 9 half of the same forward. It is still the method the system calls when
	/// the URL arrives from an app that opened it the old way, and the SDK keeps its own entry point
	/// for it — so an app that only implements the `options:` variant loses those opens silently.
	func handleOpen(_ url: URL, sourceApplication: String?, annotation: Any?) {
		debugLog(tag: Self.tag, "open (legacy): \(url.absoluteString), sourceApplication \(sourceApplication ?? "none")")
		guard isConfigured else {
			debugLog(tag: Self.tag, "open (legacy): the layer is off — the URL does not reach the SDK")
			return
		}
		AppsFlyerLib.shared().handleOpen(url, sourceApplication: sourceApplication, withAnnotation: annotation)
		debugLog(tag: Self.tag, "open (legacy): forwarded to the SDK unchanged")
	}

	func startAppsFlyer() {
		// AF-01 row 2: the first session of the process waits for the ATT answer, because as of SDK
		// 7.0 nothing else does. An install that goes out before the dialog is over carries no IDFA,
		// and a click that can only be matched by one is then attributed to nobody — the install lands
		// as organic and the campaign that paid for it never sees it. Every later foreground cycle
		// goes straight through: the question is settled once per process, not once per session.
		guard didStartAppsFlyer || isTrackingAnswered else {
			guard !isSessionHeldForTracking else {
				debugLog(tag: Self.tag, "start: a session is already held for the ATT answer — this cycle joins it rather than queuing a second one")
				return
			}
			isSessionHeldForTracking = true
			debugLog(tag: Self.tag, "start held: no ATT answer yet, waiting up to \(attTimeout)s so the install data can carry the IDFA")
			DispatchQueue.main.asyncAfter(deadline: .now() + attTimeout) { [weak self] in
				guard let self, self.isSessionHeldForTracking else { return }
				self.isSessionHeldForTracking = false
				debugLog(tag: Self.tag, level: .error, "no ATT answer in \(self.attTimeout)s — the session goes out without the IDFA. The app never called updateTrackingAuthorization; attribution that needs ID matching will read as organic")
				self.sendSession()
			}
			return
		}
		sendSession()
	}

	/// AF-01 row 2. The app's ATT answer, whatever it is — the value is not passed to the SDK, which
	/// reads the identifier itself. What matters here is that the dialog is over, so a session held
	/// for it can go out now instead of waiting out the whole timeout.
	func updateTrackingAuthorization(_ status: ATTrackingManager.AuthorizationStatus) {
		debugLog(tag: Self.tag, "ATT answer \(status.rawValue) recorded — the question is settled for this process")
		isTrackingAnswered = true
		guard isSessionHeldForTracking else { return }
		isSessionHeldForTracking = false
		debugLog(tag: Self.tag, "the session held for that answer goes out now")
		sendSession()
	}

	/// What iOS hands out when there is no advertising identifier — a simulator, or an ATT answer that
	/// was not `authorized`. The SDK reports it as a normal value rather than as nothing, so the zeros
	/// are the only way to tell "no IDFA" from "an IDFA".
	private static let blankAdvertisingId = "00000000-0000-0000-0000-000000000000"

	private func sendSession() {
		let isFirst = !didStartAppsFlyer
		didStartAppsFlyer = true
		// AF-01 row 2, the half that only a device can answer. The identifier below is what the SDK is
		// about to send with this session, and it decides which kinds of attribution are even possible:
		// with it a click can be matched by id, without it only by fingerprint — and an install that
		// needed id matching comes back organic no matter which campaign paid for it. Nothing here can
		// fix that; what it can do is say so out loud, so "why is this organic" is read off the log
		// instead of being investigated from scratch.
		let advertisingId = AppsFlyerLib.shared().advertisingIdentifier
		if advertisingId.isEmpty || advertisingId == Self.blankAdvertisingId {
			debugLog(tag: Self.tag, level: .error, "no IDFA for this session — a simulator, a denied ATT answer, or the no-IDFA build of the SDK. Only fingerprint attribution is left, and an install that needs ID matching will read as organic")
		} else {
			debugLog(tag: Self.tag, "IDFA \(advertisingId) goes out with this session — ID matching is possible")
		}
		AppsFlyerLib.shared().start()
		// AF-02 row 1: every foreground cycle starts a session; near-identical ones are collapsed by
		// the SDK's own `minTimeBetweenSessions`, so a repeat here is expected, not a bug.
		debugLog(tag: Self.tag, isFirst ? "started — first session of this process" : "started — another foreground cycle")
	}
}

extension AppsFlyerService: AppsFlyerLibDelegate {

	func onConversionDataSuccess(_ installData: [AnyHashable: Any]) {
		debugLog(tag: Self.tag, "conversion data received: \(installData)")
		let cleanedData = AppsFlyerAttributionMapping.cleanedAttributionData(from: installData)
		debugLog(tag: Self.tag, "conversion data cleaned: \(installData.count) field(s) in, \(cleanedData.count) out — NSNull and non-scalar values dropped")

		// AF-03 row 3: both addressees speak from the same cleaned dictionary. Reading the raw one
		// here used to let the event say `af_status = 42` while the profile said "unknown" — the
		// same field, two answers, and a dashboard that contradicts itself.
		analytics.logEvent("af_onConversionData", properties: cleanedData)
		debugLog(tag: Self.tag, "event af_onConversionData sent with \(cleanedData.count) propertie(s)")
		// AN-03 row 4 / AF-03 row 5: the profile properties carry the bare AppsFlyer names. Decided
		// on 2026-09-10, reversing the `af_` prefix: the namespace shared with the app's own
		// properties is accepted, so an app that writes its own `status`, `media_source` or
		// `campaign_name` overwrites these — the events keep their `af_` prefix regardless.
		let properties = [
			"status": describe(cleanedData["af_status"]),
			"media_source": describe(cleanedData["media_source"]),
			"campaign_name": describe(cleanedData["campaign"]),
		]
		analytics.setUserProperties(properties)
		debugLog(tag: Self.tag, "user properties set: \(properties) — \"unknown\" means the SDK did not send that field")

		// AF-03 row 2: an empty UID is "no UID". An empty string is worse than nothing — it looks
		// like a real identifier and links the profile to nobody, permanently.
		let appsFlyerUID = AppsFlyerLib.shared().getAppsFlyerUID()
		debugLog(tag: Self.tag, appsFlyerUID.isEmpty ? "AppsFlyer UID is empty — Adapty gets nil, not an empty string" : "AppsFlyer UID \(appsFlyerUID) goes to Adapty as the network user id")
		adapty.updateAppsFlyerAttribution(cleanedData, networkUserId: appsFlyerUID.isEmpty ? nil : appsFlyerUID)
		debugLog(tag: Self.tag, "attribution handed to Adapty")
	}

	func onConversionDataFail(_ error: Error) {
		// AF-06 row 1: `localizedDescription` is exactly what cannot tell a dropped connection from
		// a wrong dev key, and telling them apart is the whole reason to look. The install data
		// arrives once per install, so a failure here is not something a later launch repairs.
		let nsError = error as NSError
		// Read out of `userInfo` rather than through `localizedDescription`: for a domain Foundation
		// does not know — AppsFlyer's own — the property builds "The operation couldn't be completed.
		// (AppsFlyerErrorDomain error -1009.)", which is the domain and code a second time and needs
		// the localisation machinery to say it. What the SDK actually wrote is worth keeping; what
		// Foundation invents in its place is not.
		let detail = (nsError.userInfo[NSLocalizedDescriptionKey] as? String).map { " — \($0)" } ?? ""
		debugLog(tag: Self.tag, level: .error, "conversion data failed: \(nsError.domain) \(nsError.code)\(detail) — install data arrives once per install, no later launch repairs this")
		ConfigurationIssues.shared.record(
			"AppsFlyer could not deliver install attribution: \(nsError.domain) \(nsError.code)\(detail)",
			tag: Self.tag
		)
	}

	/// `String(describing:)` rather than `as? String`: the cleaned dictionary keeps scalars of any
	/// type, and a numeric `af_status` must reach the profile as the same "42" the event carries.
	private func describe(_ value: Any?) -> String {
		guard let value else { return "unknown" }
		return String(describing: value)
	}
}

extension AppsFlyerService: AppsFlyerDeepLinkDelegate {

	func didResolveDeepLink(_ result: DeepLinkResult) {
		// The status is not interpolated here on purpose: in the real SDK it is an ObjC enum, and
		// `\(…)` on one prints `__C.…(rawValue: 0)`. Each branch below says it in words instead.
		debugLog(tag: Self.tag, "UDL: the SDK reported a resolution")
		switch result.status {
			case .found:
				guard let deepLink = result.deepLink else {
					// AF-04 row 2: the SDK said "found" and handed over nothing. A deep link the
					// campaign was paid for disappears here, and the count is what makes that
					// visible outside Xcode.
					droppedDeepLinks += 1
					debugLog(tag: Self.tag, level: .error, "UDL: status found, but deepLink is nil — dropped deep links so far: \(droppedDeepLinks)")
					return
				}
				debugLog(tag: Self.tag, "UDL: found, deeplinkValue \(deepLink.deeplinkValue ?? "none"), clickEvent \(deepLink.clickEvent.keys.sorted())")
				applyDeepLink(deeplinkValue: deepLink.deeplinkValue, clickEvent: deepLink.clickEvent)
			case .notFound:
				debugLog(tag: Self.tag, "UDL: not found")
			case .failure:
				debugLog(tag: Self.tag, level: .error, "UDL failure: \(result.error?.localizedDescription ?? "unknown")")
			@unknown default:
				debugLog(tag: Self.tag, level: .error, "UDL: unknown status")
		}
	}

	/// Testable core of the `.found` branch above. `AppsFlyerDeepLink` has no public initializer
	/// (SDK-internal only), so this takes plain types.
	func applyDeepLink(deeplinkValue: String?, clickEvent: [String: Any]) {
		let (payload, dlvValue) = AppsFlyerAttributionMapping.deepLinkPayload(deeplinkValue: deeplinkValue, clickEvent: clickEvent)
		analytics.logEvent("af_didResolveDeepLink", properties: payload)
		debugLog(tag: Self.tag, "event af_didResolveDeepLink sent, deep_link_value \(dlvValue), \(payload.count) field(s)")

		// AF-04 row 1: the `-` placeholder exists so the event keeps its fixed shape. In a profile
		// it is not a placeholder but a value, and "arrived from a link with no value" stops being
		// distinguishable from "arrived from a link whose value is a dash".
		guard let deeplinkValue, !deeplinkValue.isEmpty else {
			debugLog(tag: Self.tag, "deep link carries no value — the \"-\" placeholder stays in the event and reaches no profile")
			return
		}
		analytics.setUserProperties(["deep_link_value": dlvValue])
		adapty.setProfileValue(value: dlvValue, key: "deep_link_value")
		debugLog(tag: Self.tag, "deep_link_value \(dlvValue) written to both the analytics profile and the Adapty profile")
	}
}
