//
//  AppsFlyerServiceCheck.swift
//  IntegrationKit
//
//  Compile-only proof that AppsFlyerService.swift builds against the `AppsFlyerLib` and `UIKit`
//  stub modules outside Xcode. No behavioural asserts yet — those come later, once a schema for
//  this wrapper is approved.
//  Run:  ./Checks/appsflyer-service-check.sh
//

@main
enum AppsFlyerServiceCheck {
	static func main() {
		print("AppsFlyer compiles")
	}
}
