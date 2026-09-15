#!/bin/sh
# PM-07 rows 14-16 self-check. Pure types plus UserDefaults — no SDKs, no test framework, no Xcode project.
set -e
cd "$(dirname "$0")/.."
out="${TMPDIR:-/tmp}/price-cache-check"
swiftc -o "$out" \
	Checks/Cases/PriceCacheCheck.swift \
	Sources/IntegrationKit/Premium/Models/PremiumProduct.swift \
	Sources/IntegrationKit/Premium/Models/PremiumOffer.swift \
	Sources/IntegrationKit/Premium/Models/PremiumPeriod.swift \
	Sources/IntegrationKit/Premium/Helpers/PriceCache.swift
exec "$out"
