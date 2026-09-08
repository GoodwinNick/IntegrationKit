//
//  CrashlyticsCheck.swift
//  IntegrationKit
//
//  Compile-only proof that CrashReporter.swift and FirebaseIntegration.swift build against the
//  `FirebaseCrashlytics`/`FirebaseCore` stub modules outside Xcode. No behavioural asserts yet —
//  those come later, once a schema for this wrapper is approved.
//  Run:  ./Checks/crashlytics-check.sh
//

@main
enum CrashlyticsCheck {
	static func main() {
		print("Firebase Crashlytics compiles")
	}
}
