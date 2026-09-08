#!/bin/sh
# PM-03 self-check. Pure types only — no SDKs, no test framework, no Xcode project.
set -e
cd "$(dirname "$0")/.."
out="${TMPDIR:-/tmp}/premium-resolver-check"
swiftc -o "$out" \
	Checks/PremiumResolverCheck.swift \
	Sources/IntegrationKit/Premium/PremiumSource.swift \
	Sources/IntegrationKit/Premium/PremiumState.swift \
	Sources/IntegrationKit/Premium/PremiumAccess.swift \
	Sources/IntegrationKit/Premium/PremiumResolver.swift
exec "$out"
