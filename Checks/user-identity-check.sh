#!/bin/sh
# UI-01/UI-02 self-check — the user id rules over an in-memory Keychain. No SDKs, no test framework,
# no Xcode project, and no Security framework: the real store is not compiled in, so nothing here
# can touch the Keychain of the machine that runs it.
#
# Built WITHOUT `-D DEBUG`: the trace rows read `debugLogSink`, the one channel a release build keeps.
set -e
cd "$(dirname "$0")/.."
out="${TMPDIR:-/tmp}/user-identity-check"
swiftc -o "$out" \
	Checks/Cases/UserIdentityCheck.swift \
	Sources/IntegrationKit/Identity/KeychainStoring.swift \
	Sources/IntegrationKit/Identity/UserIdentity.swift \
	Sources/IntegrationKit/Support/LogLevel.swift \
	Sources/IntegrationKit/Support/DebugLog.swift
exec "$out"
