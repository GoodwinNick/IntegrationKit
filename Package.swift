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
		// Firebase and Amplitude keep the full major range on purpose, and the difference from the
		// three below is a decision, not an oversight. A library that narrows a range narrows it for
		// every app that consumes it: pinning Firebase to one minor here would stop an app from
		// taking a Firebase security release, and an app that already asks for a fresher minor would
		// stop resolving altogether. Apps pin; libraries range. The three SDKs below are the
		// exception, and each says why in its own comment — their APIs have broken inside a minor.
		// The cost of this choice is real and belongs to whoever reads a dashboard: the observability
		// facts in the schemas were verified against Firebase 12.0.0 and Amplitude 1.18.8, so a
		// resolver that picks a fresher minor is a resolver picking untested behaviour. That risk
		// lands on Crashlytics collection and on Amplitude batching — never on money.
		.package(url: "https://github.com/firebase/firebase-ios-sdk.git", from: "12.0.0"),
		.package(url: "https://github.com/amplitude/Amplitude-Swift.git", from: "1.18.7"),
		// Adapty змінює API всередині мінорних версій (2.11 переробила remoteConfig, 4.1 —
		// getPaywall на getFlow), тому діапазон вужчий за решту.
		//
		// 4.1.3 піднімає планку тулчейна для ВСІХ, хто підключає пакет: власний маніфест Adapty
		// оголошує `swift-tools-version: 6.2` і використовує `traits`, тож SwiftPM старший за 6.1
		// його навіть не розбере. Практично це Xcode 26.0+. Наш маніфест лишається на 5.9 — це
		// наша власна нижня межа, і піднімати її нема потреби: обмеження приходить з графа
		// залежностей, а не звідси. `docs/Integration.md` називає цю вимогу явно.
		.package(url: "https://github.com/adaptyteam/AdaptySDK-iOS", .upToNextMinor(from: "4.1.3")),
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
