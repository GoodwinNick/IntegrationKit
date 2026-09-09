#!/bin/sh
# AppsFlyerService self-check — 24 asserts over 18 of the 25 rows of the approved schemas
# AF-01…AF-06. No XCTest, no Xcode project.
#
# `AppsFlyerService` also names `AnalyticsTracking` and `AdaptyServicing`, so both come straight
# from Sources/ — same trick every premium check uses for `AdaptyPurchaseResult`. Neither protocol
# actually imports `Adapty`, so no real `Adapty` stub module is built or linked here.
#
# Built WITHOUT `-D DEBUG` on purpose, unlike crashlytics-check.sh: four rows ask for a trace that
# survives outside Xcode, and that claim is only meaningful against the build the user gets.
#
# A non-zero exit here is the expected, healthy outcome — nine asserts state spec the wrapper does
# not implement yet (the ATT limit and the debug key as parameters, the second-configure guard, the
# empty AppsFlyer UID, one source for event and profile, the attribution retry, the `-` placeholder
# leaking into profiles, and both halves of the restoration answer). `set -e` still applies to a
# genuine compile failure, same as every other check.
set -e
cd "$(dirname "$0")/.."
work="${TMPDIR:-/tmp}/appsflyer-service-check"
rm -rf "$work"
mkdir -p "$work"
swiftc -emit-module -emit-library -static \
	-module-name UIKit \
	-emit-module-path "$work/UIKit.swiftmodule" \
	-o "$work/libUIKit.a" \
	Checks/Stubs/UIKitShim/UIApplication.swift \
	Checks/Stubs/UIKitShim/UIUserActivityRestoring.swift
swiftc -emit-module -emit-library -static \
	-module-name AppsFlyerLib \
	-emit-module-path "$work/AppsFlyerLib.swiftmodule" \
	-o "$work/libAppsFlyerLib.a" \
	-I "$work" \
	Checks/Stubs/AppsFlyerLib/DeepLinkResultStatus.swift \
	Checks/Stubs/AppsFlyerLib/ContinueBehaviour.swift \
	Checks/Stubs/AppsFlyerLib/AppsFlyerDeepLink.swift \
	Checks/Stubs/AppsFlyerLib/DeepLinkResult.swift \
	Checks/Stubs/AppsFlyerLib/AppsFlyerLibDelegate.swift \
	Checks/Stubs/AppsFlyerLib/AppsFlyerDeepLinkDelegate.swift \
	Checks/Stubs/AppsFlyerLib/AppsFlyerLib.swift
swiftc -o "$work/check" -I "$work" -L "$work" -lAppsFlyerLib -lUIKit \
	Checks/AppsFlyerServiceCheck.swift \
	Sources/IntegrationKit/Support/LogLevel.swift \
	Sources/IntegrationKit/Support/DebugLog.swift \
	Sources/IntegrationKit/Amplitude/AnalyticsTracking.swift \
	Sources/IntegrationKit/Adapty/AdaptyPurchaseResult.swift \
	Sources/IntegrationKit/Adapty/AdaptyServicing.swift \
	Sources/IntegrationKit/Premium/Models/PaywallState.swift \
	Sources/IntegrationKit/Premium/Models/RemoteValue.swift \
	Sources/IntegrationKit/AppsFlyer/AppsFlyerAttributionMapping.swift \
	Sources/IntegrationKit/AppsFlyer/AppsFlyerServicing.swift \
	Sources/IntegrationKit/AppsFlyer/AppsFlyerService.swift
exec "$work/check"
