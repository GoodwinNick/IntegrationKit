//
//  Analytics.swift
//  IntegrationKit — Checks/Stubs/FirebaseAnalytics
//
//  Stand-in for the `Analytics` namespace of the `FirebaseAnalytics` product (Firebase 12.19.2).
//  Compiled into a module called `FirebaseAnalytics`, so `FirebaseAnalyticsMirror` builds and runs
//  outside Xcode with its `import FirebaseAnalytics` untouched. The real type is a set of static
//  calls, never an injected instance, so every call is recorded on static vars — same idea as the
//  `Amplitude`, `Crashlytics` and `Adapty` stubs. `reset()` clears every recording; call it at the
//  top of each row so one row's setup cannot leak into the next.
//
//  What this stub deliberately does NOT model, all three on purpose:
//
//  * **No limits.** The real SDK drops a string longer than 100 characters, an event named
//    `first_open`, a 26th parameter — and says so only in DebugView. The stub accepts everything and
//    records it as given, because what FA-02 and FA-03 pin is what the PACKAGE hands over, and a stub
//    that enforced Firebase's rules would hide the very mistakes the rows exist to catch.
//  * **`logTransaction` is generic.** Upstream it takes `StoreKit.Transaction`
//    (`FirebaseAnalytics.swiftinterface:15`), which has no public initialiser — a harness cannot
//    build one, and a stub that demanded one could never be called. The package passes the function
//    itself (`send: Analytics.logTransaction`), so it compiles against both: here with whatever the
//    check hands in, upstream with a real `Transaction`. What lands in `transactions` is
//    `String(describing:)` of that value.
//  * **`FirebaseApp` is not touched here.** "Is Firebase up" lives in the `FirebaseCore` stub
//    (`Checks/Stubs/FirebaseCrashlytics/FirebaseApp.swift`), which is where the real SDK keeps it.
//

import Foundation

public final class Analytics {
	private init() {}

	private static let lock = NSLock()

	public static private(set) var loggedEvents: [(name: String, parameters: [String: Any]?)] = []
	/// `value == nil` is how the real SDK removes a property (`FIRAnalytics.h:85-86`).
	public static private(set) var userProperties: [(name: String, value: String?)] = []
	public static private(set) var userIDs: [String?] = []
	public static private(set) var collectionEnabledCalls: [Bool] = []
	public static private(set) var transactions: [String] = []
	public static private(set) var appInstanceIDReads = 0
	/// Every call by kind, in the order it arrived: `setUserID`, `setUserProperty:<name>`,
	/// `logEvent:<name>`. FA-03 row 7 is about ORDER — the user id has to land before the first event —
	/// and the separate arrays above cannot say which came first.
	public static private(set) var callOrder: [String] = []

	/// What `appInstanceID()` answers. `nil` is a legal answer (`FIRAnalytics.h:127-129`).
	public static var stubAppInstanceID: String? = "stub-app-instance-id"

	public static func reset() {
		lock.lock()
		defer { lock.unlock() }
		loggedEvents = []
		userProperties = []
		userIDs = []
		collectionEnabledCalls = []
		transactions = []
		appInstanceIDReads = 0
		callOrder = []
		stubAppInstanceID = "stub-app-instance-id"
	}

	public static func logEvent(_ name: String, parameters: [String: Any]?) {
		lock.lock()
		defer { lock.unlock() }
		loggedEvents.append((name, parameters))
		callOrder.append("logEvent:\(name)")
	}

	public static func setUserProperty(_ value: String?, forName name: String) {
		lock.lock()
		defer { lock.unlock() }
		userProperties.append((name, value))
		callOrder.append("setUserProperty:\(name)")
	}

	public static func setUserID(_ userID: String?) {
		lock.lock()
		defer { lock.unlock() }
		userIDs.append(userID)
		callOrder.append("setUserID")
	}

	public static func setAnalyticsCollectionEnabled(_ enabled: Bool) {
		lock.lock()
		defer { lock.unlock() }
		collectionEnabledCalls.append(enabled)
	}

	public static func appInstanceID() -> String? {
		lock.lock()
		defer { lock.unlock() }
		appInstanceIDReads += 1
		return stubAppInstanceID
	}

	public static func logTransaction<T>(_ transaction: T) {
		lock.lock()
		defer { lock.unlock() }
		transactions.append(String(describing: transaction))
	}
}
