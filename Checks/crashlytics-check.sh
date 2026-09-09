#!/bin/sh
# CrashReporter/FirebaseIntegration self-check — 11 rows from the approved schemas CR-01 and CR-02.
# No XCTest, no Xcode project.
#
# `-D DEBUG` on the final build on purpose: it is the build in which the collection flag used to be
# forced to `false` by an `#if DEBUG` inside the package, so it is the build that proves CR-01
# row 2 — the app's answer wins over the compiler's. It is also the build in which `debugLog`
# prints, which is what lets CR-02 row 9 read a log line back through `debugLogSink`.
#
# A non-zero exit is a regression, not the expected outcome: every row this covers is implemented.
# `set -e` still applies to a genuine compile failure, same as every other check.
set -e
cd "$(dirname "$0")/.."
work="${TMPDIR:-/tmp}/crashlytics-check"
rm -rf "$work"
mkdir -p "$work"
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
swiftc -D DEBUG -o "$work/check" -I "$work" -L "$work" -lFirebaseCore -lFirebaseCrashlytics \
	Checks/CrashlyticsCheck.swift \
	Sources/IntegrationKit/Firebase/CrashReporting.swift \
	Sources/IntegrationKit/Firebase/CrashReporter.swift \
	Sources/IntegrationKit/Firebase/FirebaseIntegration.swift \
	Sources/IntegrationKit/Support/ConfigurationIssues.swift \
	Sources/IntegrationKit/Support/DebugLog.swift \
	Sources/IntegrationKit/Support/LogLevel.swift
exec "$work/check"
