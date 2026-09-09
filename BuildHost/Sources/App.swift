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
			sharedSecret: "00000000000000000000000000000000",
			productIds: ["year.sub", "week.sub"],
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

	/// Everything a paywall screen needs, from the facade alone. Every case of every public enum is
	/// spelled out rather than defaulted: an exhaustive `switch` is what turns a case added to the
	/// package into a compile error here instead of a silently unhandled state in a real app.
	func paywall() {
		guard let kit else { return }
		kit.premium.logPaywallOpen(placement: "main")

		let title: RemoteValue<String> = kit.premium.remoteValue(placement: "main", key: "title")
		switch title {
			case .value(let text): print(text)
			case .notReady: print("paywall has not arrived — ask again")
			case .noConfig: print("paywall carries no remote config")
			case .notSet: print("no such key in the config")
			case .wrongType: print("the dashboard set another type — see configurationIssues")
		}

		switch kit.premium.paywallState(placement: "main") {
			case .ready: print("draw the paywall")
			case .loading: print("spinner")
			case .unavailable: print("fall back to a hardcoded screen")
		}
		print(kit.premium.hasPaywall(placement: "main"))

		kit.premium.products(placement: "main") { products in
			print(products.map { $0.localizedPrice ?? "—" })
		}
		kit.premium.product("year.sub", placement: "main") { product in
			guard let product else { return }
			kit.premium.purchase(product.id, placement: "main") { outcome in
				switch outcome {
					case .purchased: print("premium is already \(kit.premium.isPremium)")
					case .cancelled: print("the user said no")
					case .pending: print("waiting for approval — no error, no second button")
					case .unavailable: print("hide the button, a retry fails the same way")
					case .failed: print("temporary — offer a retry")
				}
			}
		}
		kit.premium.restore { outcome in
			switch outcome {
				case .restored: print("restored, premium: \(kit.premium.isPremium)")
				case .nothingToRestore: print("nothing to restore")
				case .failed: print("restore failed")
			}
		}
		kit.premium.refresh()

		// Empty is the healthy state. Anything in here is a cause no retry will fix.
		kit.premium.configurationIssues.forEach { print("[IntegrationKit] \($0)") }
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
