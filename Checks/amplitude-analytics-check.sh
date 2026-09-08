#!/bin/sh
# AmplitudeAnalytics/AmplitudeIDFAPlugin self-check — compile proof only, no XCTest, no Xcode
# project. No behavioural asserts yet — those come later, once a schema for this wrapper is
# approved.
set -e
cd "$(dirname "$0")/.."
work="${TMPDIR:-/tmp}/amplitude-analytics-check"
rm -rf "$work"
mkdir -p "$work"
swiftc -emit-module -emit-library -static \
	-module-name AmplitudeSwift \
	-emit-module-path "$work/AmplitudeSwift.swiftmodule" \
	-o "$work/libAmplitudeSwift.a" \
	Checks/Stubs/AmplitudeSwift/Configuration.swift \
	Checks/Stubs/AmplitudeSwift/BaseEvent.swift \
	Checks/Stubs/AmplitudeSwift/EnrichmentPlugin.swift \
	Checks/Stubs/AmplitudeSwift/Amplitude.swift
swiftc -o "$work/check" -I "$work" -L "$work" -lAmplitudeSwift \
	Checks/AmplitudeAnalyticsCheck.swift \
	Sources/IntegrationKit/Support/DebugLog.swift \
	Sources/IntegrationKit/Amplitude/AnalyticsTracking.swift \
	Sources/IntegrationKit/Amplitude/AmplitudeAnalytics.swift \
	Sources/IntegrationKit/Amplitude/AmplitudeIDFAPlugin.swift
exec "$work/check"
