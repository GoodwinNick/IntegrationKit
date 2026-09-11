//
//  TestModeGraph.swift
//  IntegrationKit
//
//  TM-01: the decision taken once per process — build the graph from the real sources or from fake
//  ones. Everything else in this layer is a consequence of it.
//
//  The package has no safeguard of its own against being in this state in production, and must not
//  have one: whether a launch is a test launch is the app's call, and a library second-guessing it
//  from the arguments or the build type would be overruling the only side that can know. What it
//  does instead is refuse to be quiet about it — an active test mode always leaves a line in
//  `configurationIssues`, which apps read in release too (TM-01 row 1, invariant 2).
//

import Foundation

struct TestModeGraph {

	private static let tag = "TestMode"

	/// The environment variable carrying the analytics sink's path. An environment variable and not a
	/// launch argument on purpose: arguments land in `NSArgumentDomain`, which outranks everything in
	/// `UserDefaults`, and a name that collided with an app's key would shadow it silently (TM-07).
	static let sinkPathVariable = "UITEST_ANALYTICS_LOG"

	let flags: TestModeFlags
	let analytics: SinkAnalytics
	let adapty: FakeAdaptySource
	let apple: FakeAppleStore
	let remoteConfig: FakeRemoteConfig
	let store: PremiumStateStoring

	/// `arguments` and `environment` are handed in rather than read here, for the same reason the
	/// parse is a pure function: a check has to be able to supply its own (TM-02 row 1, TM-07 row 2).
	/// `ProcessInfo` is touched in exactly one place, the call site in `IntegrationKit.configure`, and
	/// only when the app said this is a test run.
	static func make(
		arguments: [String],
		environment: [String: String],
		levels: Set<String>,
		productIds: Set<String>,
		remoteConfigDefaults: [String: NSObject]
	) -> TestModeGraph {
		let flags = TestModeFlagParser.parse(arguments)

		// Invariant 2: the loudest thing this layer does. An app that somehow shipped with the mode on
		// finds out from the list it already reads, rather than from its revenue.
		ConfigurationIssues.shared.record(
			"IntegrationKit is running in TEST MODE — every SDK is replaced by a fake source and nothing leaves the process. If you are seeing this in production, the app passed isTestsRunning: true",
			tag: tag
		)
		for issue in flags.issues {
			ConfigurationIssues.shared.record(issue, tag: tag)
		}
		debugLog(tag: tag, "active: Adapty \(flags.adapty), receipt \(flags.receipt) after \(flags.receiptDelay)s, purchase \(flags.purchase) after \(flags.purchaseDelay)s, restore \(flags.restore), \(flags.paywallValues.count) paywall values, \(flags.remoteConfigValues.count) remote config values")

		let sink = makeSink(environment: environment)

		// TM-03 row 7: the stored verdict is wiped before anything reads it — that is, before
		// `PremiumService.start()`, which publishes the cache before any source has answered. A wipe
		// racing with the start leaves the previous run's premium in this one, and a suite that fails
		// selectively and passes one test at a time.
		let store = UserDefaultsPremiumStore()
		if flags.noPremiumCache {
			store.cached = nil
			debugLog(tag: tag, "stored verdict wiped before start")
		}
		// The legacy flag is the app's own starting state, not an answer from any source, which is why
		// it is a separate flag and a separate field (TM-02 row 8). It is not implied by the wipe and
		// does not imply one: a test that wants "app started with the old flag on and nothing cached"
		// passes both.
		if flags.legacyPremium {
			store.premium = true
		}

		return TestModeGraph(
			flags: flags,
			analytics: SinkAnalytics(sink: sink),
			adapty: FakeAdaptySource(flags: flags, levels: levels, productIds: productIds, sink: sink),
			apple: FakeAppleStore(flags: flags, productIds: productIds),
			remoteConfig: FakeRemoteConfig(values: flags.remoteConfigValues, defaults: remoteConfigDefaults),
			store: store
		)
	}

	private static func makeSink(environment: [String: String]) -> AnalyticsSink? {
		guard let path = environment[sinkPathVariable], !path.isEmpty else {
			// TM-07 row 1: no path, no file. There is no default location — a unit run that wanted
			// nothing written must not leave anything behind, and this line is how a UI test that
			// expected a sink finds out it did not get one.
			debugLog(tag: tag, "no \(sinkPathVariable) in the environment — analytics events are not recorded anywhere")
			return nil
		}
		guard let sink = AnalyticsSink(path: path) else {
			ConfigurationIssues.shared.record(
				"test mode could not open the analytics sink at \(path) — events are not recorded; check the path the test base generated",
				tag: tag
			)
			return nil
		}
		debugLog(tag: tag, "analytics sink for this run: \(path)")
		return sink
	}
}
