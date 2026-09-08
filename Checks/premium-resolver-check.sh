#!/bin/sh
# PM-03 self-check. Pure types only — no SDKs, no test framework, no Xcode project.
set -e
cd "$(dirname "$0")/.."
out="${TMPDIR:-/tmp}/premium-resolver-check"
swiftc -o "$out" \
	Checks/PremiumResolverCheck.swift \
	Sources/IntegrationKit/PremiumSource.swift \
	Sources/IntegrationKit/PremiumState.swift \
	Sources/IntegrationKit/PremiumAccess.swift \
	Sources/IntegrationKit/PremiumResolver.swift
exec "$out"
