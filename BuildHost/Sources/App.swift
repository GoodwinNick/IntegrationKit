//
//  App.swift
//  BuildHost
//
//  The consumer side of the boundary. This app is never run — it exists so the compiler proves
//  that the public API is enough to wire IntegrationKit up. If anything here needed a type the
//  package keeps internal, the build would say so.
//

import AppTrackingTransparency
import IntegrationKit
import SwiftUI
import UIKit

/// The Apple half of the premium state — StoreKit is the app's zone, so the app implements it.
/// Stubbed out here: this build host only has to compile.
final class AppStoreKit: AppleSubscribing {
	func checkReceipt() async -> Bool? { nil }
	func restore() async -> RestoreOutcome { .nothingToRestore }
	func purchase(productId: String) async -> PurchaseOutcome { .failed }
}

final class AppDelegate: NSObject, UIApplicationDelegate {

	private var kit: IntegrationKit?

	func application(
		_ application: UIApplication,
		didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
	) -> Bool {
		FirebaseIntegration.configure()

		let kit = IntegrationKit.configure(
			deviceId: "00000000-0000-0000-0000-000000000000",
			amplitudeKey: ObfuscatedSecret.reveal(encrypted: "", secret: "fake-secret"),
			adaptyKey: "public_live_fake_adapty_key",
			placements: ["main", "onboarding"],
			sessionsCounter: 1,
			apple: AppStoreKit(),
			levels: ["premium"],
			firstOpenEvent: "first_open",
			appsFlyerDevKey: "fakeDevKey",
			appsFlyerAppId: "1234567890"
		)
		self.kit = kit

		NotificationCenter.default.addObserver(
			forName: .premiumDidChange,
			object: nil,
			queue: .main
		) { _ in
			print("premium is now \(kit.premium.isPremium)")
		}

		kit.analytics.logEvent("app_open")
		kit.crashes.recordNonFatal("launch", NSError(domain: "BuildHost", code: 1))
		return true
	}

	func application(
		_ application: UIApplication,
		continue userActivity: NSUserActivity,
		restorationHandler: @escaping ([UIUserActivityRestoring]?) -> Void
	) -> Bool {
		kit?.handleContinue(userActivity, restorationHandler: restorationHandler)
		return true
	}

	func application(_ app: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
		kit?.handleOpen(url, options: options)
		return true
	}

	/// Everything a paywall screen needs, from the facade alone.
	func paywall() {
		guard let kit else { return }
		kit.premium.logPaywallOpen(placement: "main")
		let title: String? = kit.premium.remoteValue(placement: "main", key: "title")
		print(title ?? "", kit.premium.hasPaywall(placement: "main"))
		kit.premium.products(placement: "main") { products in
			print(products.map(\.localizedPrice))
		}
		kit.premium.product("year.sub", placement: "main") { product in
			guard let product else { return }
			kit.premium.purchase(product.id, placement: "main") { outcome in
				print("purchase: \(outcome)")
			}
		}
		kit.premium.restore { outcome in
			print("restore: \(outcome), premium: \(kit.premium.isPremium)")
		}
		kit.premium.refresh()
	}

	func askTracking() {
		ATTrackingManager.requestTrackingAuthorization { [weak self] status in
			self?.kit?.updateTrackingAuthorization(status)
		}
	}
}

@main
struct BuildHostApp: App {
	@UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate

	var body: some Scene {
		WindowGroup { Text("IntegrationKit build host") }
	}
}
