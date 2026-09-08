#!/bin/sh
# CrashReporter/FirebaseIntegration self-check — 7 rows from the approved schemas CR-01 and CR-02.
# No XCTest, no Xcode project.
#
# `-D DEBUG` on the final build so FirebaseIntegration's `#if DEBUG` block — the one line that
# calls `setCrashlyticsCollectionEnabled` — is actually type-checked and not silently skipped.
#
# A non-zero exit here is the expected, healthy outcome until CR-01 row 3 (a second configure must
# be a no-op) and CR-02 row 1 (the tag must reach Crashlytics) are implemented. `set -e` still
# applies to a genuine compile failure, same as every other check.
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
