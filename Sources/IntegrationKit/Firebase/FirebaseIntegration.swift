//
//  FirebaseIntegration.swift
//  IntegrationKit
//

import FirebaseCore
import FirebaseCrashlytics

/// Firebase Core and Crashlytics. A namespace rather than a service: this layer holds no state, so
/// it stays outside the kit `IntegrationKit.configure(...)` builds and is brought up before it.
public enum FirebaseIntegration {

	/// Brings Firebase up. Call once, before `IntegrationKit.configure(...)`.
	///
	/// `isDebug` is the app's own `#if DEBUG`, and it is the only thing that decides crash
	/// collection: collection is on exactly when `isDebug` is `false`. It carries no default,
	/// because a default is the package guessing the build type — and an `#if DEBUG` compiled into
	/// a package cannot be turned off by whoever needs it off. That is the developer who wants to
	/// see their own test crash in the dashboard: they pass `isDebug: false` from a debug build and
	/// get it, without making a Release build (CR-01 row 2).
	///
	/// The app's other key, `isTestsRunning`, deliberately does not reach here. It silences
	/// Amplitude, Adapty and AppsFlyer and leaves Firebase alive: a test run that was meant to
	/// catch crashes must not be the run that loses them.
	///
	/// The flag is written on every launch in both directions on purpose (CR-01 row 4): Crashlytics
	/// persists it in `NSUserDefaults` under `com.crashlytics.data_collection`
	/// (`FIRCLSDataCollectionArbiter.m:116`), so a build that only ever switches collection off
	/// leaves the device off for every build installed after it. It also does not apply until the
	/// next launch — the first run after a change still behaves the old way, the SDK's rule, not
	/// ours.
	public static func configure(isDebug: Bool) {
		// CR-01 row 3: the second `FirebaseApp.configure()` throws an `NSException` that Swift
		// cannot catch, so a second entry point — a SceneDelegate beside an AppDelegate — kills the
		// app at launch. Asking the SDK whether it is already up costs one call and makes the second
		// configuration a no-op instead.
		guard FirebaseApp.app() == nil else { return }

		FirebaseApp.configure()
		Crashlytics.crashlytics().setCrashlyticsCollectionEnabled(!isDebug)
	}
}
