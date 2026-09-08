// swift-tools-version: 5.9
import PackageDescription

let package = Package(
	name: "IntegrationKit",
	platforms: [
		.iOS("15.6")
	],
	products: [
		.library(
			name: "IntegrationKit",
			targets: ["IntegrationKit"]
		)
	],
	dependencies: [
		.package(url: "https://github.com/firebase/firebase-ios-sdk.git", from: "12.0.0"),
		.package(url: "https://github.com/amplitude/Amplitude-Swift.git", from: "1.18.7"),
		// Adapty змінює API всередині мінорних версій (2.11 переробила remoteConfig),
		// тому діапазон вужчий за решту: обидві апки сидять на 2.10.x.
		.package(url: "https://github.com/adaptyteam/AdaptySDK-iOS", .upToNextMinor(from: "2.10.4")),
		// AppsFlyer is a binary xcframework — pinned the same way as Adapty, a fresher minor
		// broke the previous package once already.
		.package(url: "https://github.com/AppsFlyerSDK/AppsFlyerFramework", .upToNextMinor(from: "7.0.2")),
		// Pinned the same way as Adapty, for the same reason: the receipt/purchase mechanics here
		// are copied from an app already shipping on 0.16.x, and SwiftyStoreKit has changed
		// callback shapes inside a minor before. A price or a receipt check is not the place to
		// find that out from a resolver upgrade.
		.package(url: "https://github.com/bizz84/SwiftyStoreKit", .upToNextMinor(from: "0.16.4"))
	],
	targets: [
		.target(
			name: "IntegrationKit",
			dependencies: [
				.product(name: "FirebaseCore", package: "firebase-ios-sdk"),
				.product(name: "FirebaseCrashlytics", package: "firebase-ios-sdk"),
				.product(name: "AmplitudeSwift", package: "Amplitude-Swift"),
				.product(name: "Adapty", package: "AdaptySDK-iOS"),
				.product(name: "AppsFlyerLib", package: "AppsFlyerFramework"),
				.product(name: "SwiftyStoreKit", package: "SwiftyStoreKit")
			]
		)
	]
)
