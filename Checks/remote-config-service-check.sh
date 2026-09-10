#!/bin/sh
# RemoteConfigService self-check — 12 rows from the approved schemas RC-01, RC-02 and RC-03.
# No XCTest, no Xcode project.
#
# Built WITHOUT `-D DEBUG`, same as `appsflyer-service-check.sh`: every row is measured against the
# build a user actually gets. `debugLog` prints nothing there, so the one row that reads a trace
# (T8, the skipped fetch of a test run) has to read it through `debugLogSink` — the only channel
# that survives a release build.
#
# `FirebaseCore` and `FirebaseCrashlytics` come from the Crashlytics stubs: the layer needs the
# first for its "is Firebase up" guard and the second because a failed fetch is a non-fatal, which
# means the noise filter in `CrashReporter` is part of this contract too.
#
# A non-zero exit is a regression, not the expected outcome: every row this covers is implemented.
# `set -e` still applies to a genuine compile failure, same as every other check.
set -e
cd "$(dirname "$0")/.."
work="${TMPDIR:-/tmp}/remote-config-service-check"
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
swiftc -emit-module -emit-library -static \
	-module-name FirebaseRemoteConfig \
	-emit-module-path "$work/FirebaseRemoteConfig.swiftmodule" \
	-o "$work/libFirebaseRemoteConfig.a" \
	Checks/Stubs/FirebaseRemoteConfig/RemoteConfigFetchAndActivateStatus.swift \
	Checks/Stubs/FirebaseRemoteConfig/RemoteConfigSettings.swift \
	Checks/Stubs/FirebaseRemoteConfig/RemoteConfigValue.swift \
	Checks/Stubs/FirebaseRemoteConfig/RemoteConfig.swift
swiftc -o "$work/check" -I "$work" -L "$work" \
	-lFirebaseCore -lFirebaseCrashlytics -lFirebaseRemoteConfig \
	Checks/Cases/RemoteConfigServiceCheck.swift \
	Sources/IntegrationKit/Firebase/RemoteConfigServicing.swift \
	Sources/IntegrationKit/Firebase/RemoteConfigService.swift \
	Sources/IntegrationKit/Firebase/CrashReporting.swift \
	Sources/IntegrationKit/Firebase/CrashReporter.swift \
	Sources/IntegrationKit/Support/ConfigurationIssues.swift \
	Sources/IntegrationKit/Support/DebugLog.swift \
	Sources/IntegrationKit/Support/LogLevel.swift
exec "$work/check"
