#!/bin/sh
# PM-05 (restore) and PM-08 (unfinished transactions) self-check — no XCTest, no Xcode project.
# `StoreKitService` names `Adapty` (through `PremiumService`) and `SwiftyStoreKit` directly, so both
# get a stub module compiled first and linked in their place, same trick as `premium-barrier-check.sh`.
#
# This check does not stop at the first failing row — it runs every row, collects every failure, and
# exits non-zero if any row failed.
set -e
cd "$(dirname "$0")/.."
work="${TMPDIR:-/tmp}/premium-storekit-check"
rm -rf "$work"
mkdir -p "$work"
swiftc -emit-module -emit-library -static \
	-module-name Adapty \
	-emit-module-path "$work/Adapty.swiftmodule" \
	-o "$work/libAdapty.a" \
	Checks/Stubs/AdaptyProfile.swift
swiftc -emit-module -emit-library -static \
	-module-name SwiftyStoreKit \
	-emit-module-path "$work/SwiftyStoreKit.swiftmodule" \
	-o "$work/libSwiftyStoreKit.a" \
	Checks/Stubs/SwiftyStoreKit.swift
swiftc -o "$work/check" -I "$work" -L "$work" -lAdapty -lSwiftyStoreKit \
	Checks/Cases/PremiumStoreKitCheck.swift \
	Sources/IntegrationKit/Support/LogLevel.swift \
	Sources/IntegrationKit/Support/DebugLog.swift \
	Sources/IntegrationKit/Support/ConfigurationIssues.swift \
	Sources/IntegrationKit/Support/SingleResume.swift \
	Sources/IntegrationKit/Support/WithTimeout.swift \
	Sources/IntegrationKit/StoreKit/StoreKitService.swift \
	Sources/IntegrationKit/Premium/PremiumService.swift \
	Sources/IntegrationKit/Premium/Protocols/PremiumServicing.swift \
	Sources/IntegrationKit/Premium/Protocols/AdaptyPremiumProviding.swift \
	Sources/IntegrationKit/Adapty/AdaptyPurchaseResult.swift \
	Sources/IntegrationKit/Adapty/AdaptyProductsAnswer.swift \
	Sources/IntegrationKit/Premium/Models/PaywallState.swift \
	Sources/IntegrationKit/Premium/Models/RemoteValue.swift \
	Sources/IntegrationKit/Premium/Protocols/AppleSubscribing.swift \
	Sources/IntegrationKit/Premium/Protocols/PremiumStateStoring.swift \
	Sources/IntegrationKit/Premium/Models/PremiumState.swift \
	Sources/IntegrationKit/Premium/Models/ReceiptAnswer.swift \
	Sources/IntegrationKit/Premium/Models/PremiumSource.swift \
	Sources/IntegrationKit/Premium/Models/PremiumAccess.swift \
	Sources/IntegrationKit/Premium/Models/PremiumAccess+Adapty.swift \
	Sources/IntegrationKit/Premium/Models/PremiumProduct.swift \
	Sources/IntegrationKit/Premium/Models/PremiumProduct+StoreKit.swift \
	Sources/IntegrationKit/Premium/Models/PremiumPeriod.swift \
	Sources/IntegrationKit/Premium/Models/PremiumPeriod+StoreKit.swift \
	Sources/IntegrationKit/Premium/Models/PremiumOffer.swift \
	Sources/IntegrationKit/Premium/Models/PremiumOffer+StoreKit.swift \
	Sources/IntegrationKit/Premium/Models/PurchaseOutcome.swift \
	Sources/IntegrationKit/Premium/Models/RestoreOutcome.swift \
	Sources/IntegrationKit/Premium/Models/PremiumNotification.swift \
	Sources/IntegrationKit/Premium/Helpers/PremiumResolver.swift \
	Sources/IntegrationKit/Premium/Helpers/UserDefaultsPremiumStore.swift
exec "$work/check"
