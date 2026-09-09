#!/bin/sh
# Composition-root self-check — AF-05 row 3 through the public facade. No XCTest, no Xcode project.
#
# The only check that RUNS `IntegrationKit.swift`. `buildhost-check.sh` compiles it against the real
# SDKs and stops there; the other ten compile a slice of `Sources/` that leaves the root out
# entirely. Anything the root itself decides — which services get built, what the AppDelegate
# forwards do when one of them is missing — is unreachable from all eleven.
#
# So this one builds the WHOLE package (a glob, not a hand-kept list: the root pulls in every file
# anyway, and a list would go stale the first time a model file is added) against the same stub
# modules the other checks use.
#
# Built WITHOUT `-D DEBUG`, like `appsflyer-service-check.sh`: this is the build the user gets.
# A non-zero exit is a regression. `set -e` still applies to a genuine compile failure.
set -e
cd "$(dirname "$0")/.."
work="${TMPDIR:-/tmp}/integration-kit-check"
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
swiftc -emit-module -emit-library -static \
	-module-name AmplitudeSwift \
	-emit-module-path "$work/AmplitudeSwift.swiftmodule" \
	-o "$work/libAmplitudeSwift.a" \
	Checks/Stubs/AmplitudeSwift/Configuration.swift \
	Checks/Stubs/AmplitudeSwift/BaseEvent.swift \
	Checks/Stubs/AmplitudeSwift/EnrichmentPlugin.swift \
	Checks/Stubs/AmplitudeSwift/Amplitude.swift
swiftc -emit-module -emit-library -static \
	-module-name FirebaseCore \
	-emit-module-path "$work/FirebaseCore.swiftmodule" \
	-o "$work/libFirebaseCore.a" \
	Checks/Stubs/FirebaseCrashlytics/FirebaseApp.swift
swiftc -emit-module -emit-library -static \
	-module-name FirebaseCrashlytics \
	-emit-module-path "$work/FirebaseCrashlytics.swiftmodule" \
	-o "$work/libFirebaseCrashlytics.a" \
	Checks/Stubs/FirebaseCrashlytics/Crashlytics.swift
swiftc -emit-module -emit-library -static \
	-module-name SwiftyStoreKit \
	-emit-module-path "$work/SwiftyStoreKit.swiftmodule" \
	-o "$work/libSwiftyStoreKit.a" \
	Checks/Stubs/SwiftyStoreKit.swift
swiftc -o "$work/check" -I "$work" -L "$work" \
	-lUIKit -lAppsFlyerLib -lAdapty -lAmplitudeSwift -lFirebaseCore -lFirebaseCrashlytics -lSwiftyStoreKit \
	Checks/Cases/IntegrationKitCheck.swift \
	Sources/IntegrationKit/*.swift \
	Sources/IntegrationKit/*/*.swift \
	Sources/IntegrationKit/*/*/*.swift
exec "$work/check"
