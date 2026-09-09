#!/bin/sh
# AppsFlyerAttributionMapping self-check. Pure types only — no SDKs, no test framework.
set -e
cd "$(dirname "$0")/.."
out="${TMPDIR:-/tmp}/appsflyer-attribution-check"
swiftc -o "$out" \
	Checks/Cases/AppsFlyerAttributionCheck.swift \
	Sources/IntegrationKit/AppsFlyer/AppsFlyerAttributionMapping.swift
exec "$out"
