//
//  AppsFlyerLib.swift
//  IntegrationKit — Checks/Stubs/AppsFlyerLib
//
//  Stand-in for the `AppsFlyerLib` SDK class (AppsFlyerLib 7.0.x). Compiled into a module called
//  `AppsFlyerLib` alongside the other files in this folder, so `AppsFlyerService` builds and runs
//  outside Xcode with its `import AppsFlyerLib` untouched. Needs the `UIKit` shim module for
//  `UIApplication.OpenURLOptionsKey`, the same way the real SDK needs the real UIKit.
//
//  `shared()` always answers the same instance — same as the real SDK's process-wide singleton —
//  so a check can read what was set (`customerUserID`, `isDebug`, `delegate`, ...) straight off
//  it. Calls that don't already land on a settable property are recorded on static vars instead:
//  `initialize`'s arguments, the ATT wait limit, the launch options, the URL `handleOpen` was
//  handed (and, for the legacy variant, the source application with it), the
//  `customerUserID` that was in place when `start` ran, and how many times
//  `initialize`/`start`/`continue`/`handleOpen`/`handleLaunchOptions` ran. The session-ready
//  listener is kept rather than counted: firing `sessionReadyListener` is how a check plays one
//  foreground cycle, which since 7.0 is the only way a session is supposed to start. Two knobs
//  steer what the SDK answers back:
//  `appsFlyerUID` (AF-03 row 2 needs an empty one) and `continueBehaviour` (AF-05 needs a block
//  that is never called, and one that answers a mixed array). `reset()` clears every recording,
//  both knobs and the singleton's own properties; call it at the top of each row so one row's
//  setup cannot leak into the next.
//

import Foundation
import UIKit

public final class AppsFlyerLib {
	private static let instance = AppsFlyerLib()

	public static func shared() -> AppsFlyerLib {
		instance
	}

	public static private(set) var initializeCallCount = 0
	public static private(set) var lastDevKey: String?
	public static private(set) var lastAppId: String?
	public static private(set) var startCallCount = 0
	public static private(set) var continueCallCount = 0
	public static private(set) var handleOpenCallCount = 0
	/// AF-05 row 4: "forward it as it is" is a claim about the URL, not about a call happening, and a
	/// counter cannot tell a forwarded link from a different one.
	public static private(set) var lastOpenedURL: URL?
	/// The legacy forward carries one more thing the SDK is entitled to see, and "forward it as it
	/// is" covers that too — a counter would be green with it dropped.
	public static private(set) var lastOpenSourceApplication: String?
	/// AF-01: what `customerUserID` held at the moment `start()` ran. The docs are explicit that a
	/// CUID set after `start` is not associated with the install event, so the ordering is the
	/// requirement — and reading the property afterwards cannot say which came first.
	public static private(set) var customerUserIDAtStart: String?
	/// `nil` means "never asked". The package stopped calling this in 0.6.1 — the real method is
	/// deprecated in 7.0 and does nothing — so AF-01 row 2 now reads it to prove the call is gone.
	public static private(set) var lastATTTimeout: Double?
	/// AF-05: what `handleLaunchOptions(_:)` was handed, and whether it ran at all. `nil` in
	/// `lastLaunchOptions` cannot say "never called" on its own — an app with no cold-launch link
	/// passes `nil` too — so the counter is kept beside it.
	public static private(set) var handleLaunchOptionsCallCount = 0
	public static private(set) var lastLaunchOptions: [UIApplication.LaunchOptionsKey: Any]?
	/// AF-02: the block the service registered. Holding it is the whole point — a check fires it to
	/// play one foreground cycle, which is how the real SDK delivers one now.
	public static var sessionReadyListener: (() -> Void)?
	public static private(set) var registerSessionReadyListenerCallCount = 0

	/// What `getAppsFlyerUID()` answers. Settable so a check can seed it before exercising code
	/// that reads the UID.
	public static var appsFlyerUID = "stub-appsflyer-uid"

	/// How `continue(_:_:)` answers the restoration block. See `ContinueBehaviour`.
	public static var continueBehaviour: ContinueBehaviour = .callsWithNil

	public static func reset() {
		initializeCallCount = 0
		lastDevKey = nil
		lastAppId = nil
		startCallCount = 0
		continueCallCount = 0
		handleOpenCallCount = 0
		lastOpenedURL = nil
		lastOpenSourceApplication = nil
		customerUserIDAtStart = nil
		lastATTTimeout = nil
		handleLaunchOptionsCallCount = 0
		lastLaunchOptions = nil
		sessionReadyListener = nil
		registerSessionReadyListenerCallCount = 0
		appsFlyerUID = "stub-appsflyer-uid"
		continueBehaviour = .callsWithNil
		instance.customerUserID = nil
		instance.delegate = nil
		instance.deepLinkDelegate = nil
		instance.isDebug = false
	}

	public var customerUserID: String?
	public weak var delegate: AppsFlyerLibDelegate?
	public var deepLinkDelegate: AppsFlyerDeepLinkDelegate?
	public var isDebug = false

	private init() {}

	public func initialize(devKey: String, appId: String) {
		AppsFlyerLib.initializeCallCount += 1
		AppsFlyerLib.lastDevKey = devKey
		AppsFlyerLib.lastAppId = appId
	}

	public func waitForATTUserAuthorization(timeoutInterval: Double) {
		AppsFlyerLib.lastATTTimeout = timeoutInterval
	}

	public func handleLaunchOptions(_ launchOptions: [UIApplication.LaunchOptionsKey: Any]?) {
		AppsFlyerLib.handleLaunchOptionsCallCount += 1
		AppsFlyerLib.lastLaunchOptions = launchOptions
	}

	public func registerSessionReadyListener(_ listener: @escaping () -> Void) {
		AppsFlyerLib.registerSessionReadyListenerCallCount += 1
		// The real SDK replaces the current listener on a second call rather than keeping both.
		AppsFlyerLib.sessionReadyListener = listener
	}

	public func unregisterSessionReadyListener() {
		AppsFlyerLib.sessionReadyListener = nil
	}

	public func `continue`(_ userActivity: NSUserActivity, _ handler: (([Any]?) -> Void)?) {
		AppsFlyerLib.continueCallCount += 1
		switch AppsFlyerLib.continueBehaviour {
			case .neverCallsBlock:
				break
			case .callsWithNil:
				handler?(nil)
			case .callsWith(let objects):
				handler?(objects)
		}
	}

	public func handleOpen(_ url: URL, options: [UIApplication.OpenURLOptionsKey: Any]?) {
		AppsFlyerLib.handleOpenCallCount += 1
		AppsFlyerLib.lastOpenedURL = url
	}

	public func handleOpen(_ url: URL, sourceApplication: String?, withAnnotation annotation: Any?) {
		AppsFlyerLib.handleOpenCallCount += 1
		AppsFlyerLib.lastOpenedURL = url
		AppsFlyerLib.lastOpenSourceApplication = sourceApplication
	}

	public func start() {
		AppsFlyerLib.startCallCount += 1
		AppsFlyerLib.customerUserIDAtStart = customerUserID
	}

	public func getAppsFlyerUID() -> String {
		AppsFlyerLib.appsFlyerUID
	}
}
