#!/bin/sh
# PM-03 self-check. Pure types only — no SDKs, no test framework, no Xcode project.
set -e
cd "$(dirname "$0")/.."
out="${TMPDIR:-/tmp}/premium-resolver-check"
swiftc -o "$out" \
	Checks/PremiumResolverCheck.swift \
	Sources/IntegrationKit/Premium/Models/PremiumSource.swift \
	Sources/IntegrationKit/Premium/Models/PremiumState.swift \
	Sources/IntegrationKit/Premium/Models/PremiumAccess.swift \
	Sources/IntegrationKit/Premium/Helpers/PremiumResolver.swift
exec "$out"
