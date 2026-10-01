#!/bin/sh
# FirebaseAnalyticsMirror self-check — FA-01…FA-05 of the approved schemas and the AN-01 r12 /
# AN-02 r6 / AN-03 r7 boundary with `AmplitudeAnalytics`. No XCTest, no Xcode project.
#
# Red until `Sources/IntegrationKit/Firebase/FirebaseAnalyticsMirror.swift` exists and
# `AmplitudeAnalytics` hands every event, property and user id to it. A non-zero exit is the expected
# outcome until then, and a regression after.
#
# Three stub modules, each compiled first so the sources under test keep their real `import`s:
# `FirebaseCore` (the same `FirebaseApp` stub the Crashlytics check uses — "is Firebase up"),
# `FirebaseAnalytics` (the `Analytics` namespace, recording every call) and `AmplitudeSwift`.
#
# Built without `-D DEBUG` on purpose: that is what makes `debugLogSink` (`DebugLog.swift:25-27`)
# the readable destination the log asserts rely on.
set -e
cd "$(dirname "$0")/.."
work="${TMPDIR:-/tmp}/firebase-analytics-check"
rm -rf "$work"
mkdir -p "$work"
swiftc -emit-module -emit-library -static \
	-module-name FirebaseCore \
	-emit-module-path "$work/FirebaseCore.swiftmodule" \
	-o "$work/libFirebaseCore.a" \
	Checks/Stubs/FirebaseCrashlytics/FirebaseApp.swift
swiftc -emit-module -emit-library -static \
	-module-name FirebaseAnalytics \
	-emit-module-path "$work/FirebaseAnalytics.swiftmodule" \
	-o "$work/libFirebaseAnalytics.a" \
	Checks/Stubs/FirebaseAnalytics/Analytics.swift
swiftc -emit-module -emit-library -static \
	-module-name AmplitudeSwift \
	-emit-module-path "$work/AmplitudeSwift.swiftmodule" \
	-o "$work/libAmplitudeSwift.a" \
	Checks/Stubs/AmplitudeSwift/Configuration.swift \
	Checks/Stubs/AmplitudeSwift/BaseEvent.swift \
	Checks/Stubs/AmplitudeSwift/EnrichmentPlugin.swift \
	Checks/Stubs/AmplitudeSwift/Amplitude.swift
swiftc -o "$work/check" -I "$work" -L "$work" -lFirebaseCore -lFirebaseAnalytics -lAmplitudeSwift \
	Checks/Cases/FirebaseAnalyticsCheck.swift \
	Sources/IntegrationKit/Support/LogLevel.swift \
	Sources/IntegrationKit/Support/DebugLog.swift \
	Sources/IntegrationKit/Support/ConfigurationIssues.swift \
	Sources/IntegrationKit/Firebase/FirebaseAnalyticsMirror.swift \
	Sources/IntegrationKit/Amplitude/AnalyticsTracking.swift \
	Sources/IntegrationKit/Amplitude/AmplitudeAnalytics.swift \
	Sources/IntegrationKit/Amplitude/AmplitudeIDFAPlugin.swift
exec "$work/check"
