#!/bin/sh
# AmplitudeAnalytics/AmplitudeIDFAPlugin self-check — 18 asserts over 15 rows of the approved
# schemas AN-01 through AN-04. No XCTest, no Xcode project.
#
# A non-zero exit is a regression: every row this harness can reach is green as of `b6ac9ef`. The
# rows it cannot reach say so in their own risk table rather than sitting here red. `set -e` still
# applies to a genuine compile failure, same as every other check.
#
# Built without `-D DEBUG` on purpose: that is what makes `debugLogSink` (`DebugLog.swift:25-27`)
# the readable destination T14 and T15 assert the log format on.
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
	Sources/IntegrationKit/Support/ConfigurationIssues.swift \
	Sources/IntegrationKit/Amplitude/AnalyticsTracking.swift \
	Sources/IntegrationKit/Amplitude/AmplitudeAnalytics.swift \
	Sources/IntegrationKit/Amplitude/AmplitudeIDFAPlugin.swift
exec "$work/check"
