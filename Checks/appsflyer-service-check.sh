#!/bin/sh
# AppsFlyerService self-check — compile proof only, no XCTest, no Xcode project. No behavioural
# asserts yet — those come later, once a schema for this wrapper is approved.
#
# `AppsFlyerService` also names `AnalyticsTracking` and `AdaptyServicing`, so both come straight
# from Sources/ — same trick every premium check uses for `AdaptyPurchaseResult`. Neither protocol
# actually imports `Adapty`, so no real `Adapty` stub module is built or linked here.
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
	Checks/Stubs/AppsFlyerLib/AppsFlyerDeepLink.swift \
	Checks/Stubs/AppsFlyerLib/DeepLinkResult.swift \
	Checks/Stubs/AppsFlyerLib/AppsFlyerLibDelegate.swift \
	Checks/Stubs/AppsFlyerLib/AppsFlyerDeepLinkDelegate.swift \
	Checks/Stubs/AppsFlyerLib/AppsFlyerLib.swift
swiftc -o "$work/check" -I "$work" -L "$work" -lAppsFlyerLib -lUIKit \
	Checks/AppsFlyerServiceCheck.swift \
	Sources/IntegrationKit/Support/DebugLog.swift \
	Sources/IntegrationKit/Amplitude/AnalyticsTracking.swift \
	Sources/IntegrationKit/Adapty/AdaptyPurchaseResult.swift \
	Sources/IntegrationKit/Adapty/AdaptyServicing.swift \
	Sources/IntegrationKit/AppsFlyer/AppsFlyerAttributionMapping.swift \
	Sources/IntegrationKit/AppsFlyer/AppsFlyerServicing.swift \
	Sources/IntegrationKit/AppsFlyer/AppsFlyerService.swift
exec "$work/check"
