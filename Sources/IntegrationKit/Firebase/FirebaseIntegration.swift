//
//  FirebaseIntegration.swift
//  IntegrationKit
//

import FirebaseCore
import FirebaseCrashlytics

public enum FirebaseIntegration {

	/// Brings Firebase up. Call once, before `IntegrationKit.configure(...)`.
	///
	/// `collectsCrashes` is the app's answer, not the package's: an `#if DEBUG` inside a package
	/// cannot be turned off by whoever needs it off, and a developer who wants to see their own test
	/// crash in the dashboard would have to make a Release build to do it (CR-01 row 2). Pass
	/// `false` from the app's own debug flag if that is the policy — the `#if` belongs where the
	/// other developer flags already live.
	///
	/// The flag is written on every launch in both directions on purpose (CR-01 row 4): Crashlytics
	/// persists it in `NSUserDefaults`, so a Debug run that switched collection off would keep it
	/// off in the Release build installed over it. It also does not apply until the next launch —
	/// the first run after a change still behaves the old way, which is the SDK's rule, not ours.
	public static func configure(collectsCrashes: Bool = true) {
		// CR-01 row 3: the second `FirebaseApp.configure()` throws an `NSException` that Swift
		// cannot catch, so a second entry point — a SceneDelegate beside an AppDelegate — kills the
		// app at launch. Asking the SDK whether it is already up costs one call and makes the second
		// configuration a no-op instead.
		guard FirebaseApp.app() == nil else { return }

		FirebaseApp.configure()
		Crashlytics.crashlytics().setCrashlyticsCollectionEnabled(collectsCrashes)
	}
}
