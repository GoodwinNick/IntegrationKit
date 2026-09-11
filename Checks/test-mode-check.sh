#!/bin/sh
# TM-01…TM-07 self-check — the test mode. No XCTest, no Xcode project.
# Same shape as the other premium checks: a stub module called `Adapty` is compiled first, because
# the fake source forges an `AdaptyProfile` and the real SDK cannot be built outside Xcode.
set -e
cd "$(dirname "$0")/.."
work="${TMPDIR:-/tmp}/test-mode-check"
rm -rf "$work"
mkdir -p "$work"
swiftc -emit-module -emit-library -static \
	-module-name Adapty \
	-emit-module-path "$work/Adapty.swiftmodule" \
	-o "$work/libAdapty.a" \
	Checks/Stubs/Adapty/AdaptyProfile.swift
swiftc -o "$work/check" -I "$work" -L "$work" -lAdapty \
	Checks/Cases/TestModeCheck.swift \
	Sources/IntegrationKit/Support/LogLevel.swift \
	Sources/IntegrationKit/Support/DebugLog.swift \
	Sources/IntegrationKit/Support/ConfigurationIssues.swift \
	Sources/IntegrationKit/Support/SingleResume.swift \
	Sources/IntegrationKit/Support/WithTimeout.swift \
	Sources/IntegrationKit/Premium/PremiumService.swift \
	Sources/IntegrationKit/Premium/Protocols/PremiumServicing.swift \
	Sources/IntegrationKit/Premium/Protocols/AdaptyPremiumProviding.swift \
	Sources/IntegrationKit/Premium/Protocols/AppleSubscribing.swift \
	Sources/IntegrationKit/Premium/Protocols/PremiumStateStoring.swift \
	Sources/IntegrationKit/Adapty/AdaptyServicing.swift \
	Sources/IntegrationKit/Adapty/PurchaseVerdict.swift \
	Sources/IntegrationKit/Adapty/AdaptyProductsAnswer.swift \
	Sources/IntegrationKit/Amplitude/AnalyticsTracking.swift \
	Sources/IntegrationKit/Firebase/RemoteConfigServicing.swift \
	Sources/IntegrationKit/Premium/Models/PaywallState.swift \
	Sources/IntegrationKit/Premium/Models/RemoteValue.swift \
	Sources/IntegrationKit/Premium/Models/PremiumState.swift \
	Sources/IntegrationKit/Premium/Models/ReceiptAnswer.swift \
	Sources/IntegrationKit/Premium/Models/PremiumSource.swift \
	Sources/IntegrationKit/Premium/Models/PremiumAccess.swift \
	Sources/IntegrationKit/Premium/Models/PremiumAccess+Adapty.swift \
	Sources/IntegrationKit/Premium/Models/PremiumProduct.swift \
	Sources/IntegrationKit/Premium/Models/PremiumPeriod.swift \
	Sources/IntegrationKit/Premium/Models/PremiumOffer.swift \
	Sources/IntegrationKit/Premium/Models/PurchaseOutcome.swift \
	Sources/IntegrationKit/Premium/Models/RestoreOutcome.swift \
	Sources/IntegrationKit/Premium/Models/PremiumNotification.swift \
	Sources/IntegrationKit/Premium/Helpers/PremiumResolver.swift \
	Sources/IntegrationKit/Premium/Helpers/UserDefaultsPremiumStore.swift \
	Sources/IntegrationKit/TestMode/TestModeFlags.swift \
	Sources/IntegrationKit/TestMode/TestModeFlagParser.swift \
	Sources/IntegrationKit/TestMode/AnalyticsSink.swift \
	Sources/IntegrationKit/TestMode/SinkAnalytics.swift \
	Sources/IntegrationKit/TestMode/TestModeCatalog.swift \
	Sources/IntegrationKit/TestMode/TestModeProfile.swift \
	Sources/IntegrationKit/TestMode/FakeAdaptySource.swift \
	Sources/IntegrationKit/TestMode/FakeAppleStore.swift \
	Sources/IntegrationKit/TestMode/FakeRemoteConfig.swift \
	Sources/IntegrationKit/TestMode/TestModeGraph.swift
exec "$work/check"
