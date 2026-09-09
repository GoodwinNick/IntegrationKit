#!/bin/sh
# AmplitudeAnalytics/AmplitudeIDFAPlugin self-check — 11 rows from the approved schemas AN-01
# through AN-04. No XCTest, no Xcode project.
#
# A non-zero exit here is the expected, healthy outcome until AN-01 rows 1-2 (the first-open gate)
# and AN-04 rows 1-2 (double-add/pre-configure guard for the IDFA plugin) are implemented. `set -e`
# still applies to a genuine compile failure, same as every other check.
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
	Sources/IntegrationKit/Support/LogLevel.swift \
	Sources/IntegrationKit/Support/DebugLog.swift \
	Sources/IntegrationKit/Amplitude/AnalyticsTracking.swift \
	Sources/IntegrationKit/Amplitude/AmplitudeAnalytics.swift \
	Sources/IntegrationKit/Amplitude/AmplitudeIDFAPlugin.swift
exec "$work/check"
