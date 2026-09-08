//
//  LegacyAdaptyPremiumBridge.swift
//  IntegrationKit
//

import Adapty
import Foundation

/// TEMPORARY (premium rewrite step 2): bridges the still callback-based `AdaptyService` to the
/// async `AdaptyPremiumProviding` contract, so the package keeps compiling until step 3 gives
/// `AdaptyService` real async `profile()`/`products()`/`buy()` methods directly — at which
/// point this bridge is deleted.
final class LegacyAdaptyPremiumBridge: AdaptyPremiumProviding {
	private let service: AdaptyService

	var premiumObserver: ((AdaptyProfile) -> Void)? {
		get { service.premiumObserver }
		set { service.premiumObserver = newValue }
	}

	init(service: AdaptyService) {
		self.service = service
	}

	func profile() async -> AdaptyProfile? {
		await withCheckedContinuation { continuation in
			Adapty.getProfile { result in
				switch result {
					case .success(let profile):
						continuation.resume(returning: profile)
					case .failure:
						continuation.resume(returning: nil)
				}
			}
		}
	}

	func products(placement: String) async -> [PremiumProduct] {
		// The old `AdaptyService` never exposed its cached products, only booleans. Real product
		// mapping arrives with step 6 ("prices through the facade"); nothing calls this yet.
		[]
	}

	func buy(productId: String, placement: String) async -> PurchaseOutcome {
		await withCheckedContinuation { continuation in
			service.buyProduct(placement: placement, id: productId) { result in
				switch result {
					case .success:
						continuation.resume(returning: .purchased)
					case .cancelled:
						continuation.resume(returning: .cancelled)
					case .retryWithStoreKit:
						continuation.resume(returning: .retryWithStoreKit)
					case .failed:
						continuation.resume(returning: .failed)
				}
			}
		}
	}

	func remoteValue<T>(placement: String, key: String) -> T? {
		service.getRemoteValue(placement: placement, key: key)
	}

	func logPaywallOpen(placement: String) {
		service.logPaywallOpen(placement: placement)
	}

	func hasPaywall(placement: String) -> Bool {
		service.hasPaywall(placement: placement)
	}
}
