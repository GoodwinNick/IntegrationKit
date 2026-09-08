#!/bin/sh
# AdaptyService self-check — PM-07 rows 8 and 10, PM-04 row 8. No XCTest, no Xcode project.
# First time `AdaptyService.swift` itself compiles inside a check: the `Adapty` stub grows past the
# single `AdaptyProfile` type the other checks need, into the paywall/product/profile-parameters
# surface `AdaptyService` actually calls.
#
# A non-zero exit here is the expected, healthy outcome until the paywall retry and the StoreKit
# fallback are implemented — this script still uses `set -e` and exits non-zero on a genuine compile
# failure, same as every other check.
set -e
cd "$(dirname "$0")/.."
work="${TMPDIR:-/tmp}/adapty-service-check"
rm -rf "$work"
mkdir -p "$work"
swiftc -emit-module -emit-library -static \
	-module-name Adapty \
	-emit-module-path "$work/Adapty.swiftmodule" \
	-o "$work/libAdapty.a" \
	Checks/Stubs/AdaptyProfile.swift \
	Checks/Stubs/AdaptyPaywall.swift \
	Checks/Stubs/AdaptyPaywallProduct.swift \
	Checks/Stubs/AdaptyProductSubscriptionPeriod.swift \
	Checks/Stubs/AdaptyProductDiscount.swift \
	Checks/Stubs/AdaptyProfileParameters.swift \
	Checks/Stubs/AdaptyDelegate.swift \
	Checks/Stubs/AdaptyError.swift \
	Checks/Stubs/AdaptyAttributionSource.swift \
	Checks/Stubs/Adapty.swift
swiftc -o "$work/check" -I "$work" -L "$work" -lAdapty \
	Checks/AdaptyServiceCheck.swift \
	Sources/IntegrationKit/Support/DebugLog.swift \
	Sources/IntegrationKit/Support/SingleResume.swift \
	Sources/IntegrationKit/Amplitude/AnalyticsTracking.swift \
	Sources/IntegrationKit/Adapty/AdaptyPurchaseResult.swift \
	Sources/IntegrationKit/Adapty/AdaptyServicing.swift \
	Sources/IntegrationKit/Adapty/AdaptyService.swift \
	Sources/IntegrationKit/Premium/Protocols/AdaptyPremiumProviding.swift \
	Sources/IntegrationKit/Premium/Models/PremiumProduct.swift \
	Sources/IntegrationKit/Premium/Models/PremiumProduct+Adapty.swift \
	Sources/IntegrationKit/Premium/Models/PremiumPeriod.swift \
	Sources/IntegrationKit/Premium/Models/PremiumPeriod+Adapty.swift \
	Sources/IntegrationKit/Premium/Models/PremiumOffer.swift \
	Sources/IntegrationKit/Premium/Models/PremiumOffer+Adapty.swift
exec "$work/check"
