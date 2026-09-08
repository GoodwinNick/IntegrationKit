//
//  AmplitudeAnalyticsCheck.swift
//  IntegrationKit
//
//  Compile-only proof that AmplitudeAnalytics.swift and AmplitudeIDFAPlugin.swift build against
//  the `AmplitudeSwift` stub module outside Xcode. No behavioural asserts yet — those come later,
//  once a schema for this wrapper is approved.
//  Run:  ./Checks/amplitude-analytics-check.sh
//

@main
enum AmplitudeAnalyticsCheck {
	static func main() {
		print("Amplitude compiles")
	}
}
