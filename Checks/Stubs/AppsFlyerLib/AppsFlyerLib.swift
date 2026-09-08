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
//  `initialize`'s arguments, the ATT wait limit, and how many times
//  `initialize`/`start`/`continue`/`handleOpen` ran. Two knobs steer what the SDK answers back:
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
	/// `nil` means "never asked" — AF-01 row 2 has to tell a limit nobody set from the hardwired
	/// one, and a plain `Double` cannot say that.
	public static private(set) var lastATTTimeout: Double?

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
		lastATTTimeout = nil
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
	}

	public func start() {
		AppsFlyerLib.startCallCount += 1
	}

	public func getAppsFlyerUID() -> String {
		AppsFlyerLib.appsFlyerUID
	}
}
