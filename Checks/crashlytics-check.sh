#!/bin/sh
# CrashReporter/FirebaseIntegration self-check — compile proof only, no XCTest, no Xcode project.
# No behavioural asserts yet — those come later, once a schema for this wrapper is approved.
#
# `-D DEBUG` on the final build so FirebaseIntegration's `#if DEBUG` block — the one line that
# calls `setCrashlyticsCollectionEnabled` — is actually type-checked and not silently skipped.
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
	Sources/IntegrationKit/Firebase/FirebaseIntegration.swift
exec "$work/check"
