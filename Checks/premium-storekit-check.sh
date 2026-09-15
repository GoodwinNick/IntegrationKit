#!/bin/sh
# PM-05 rows 1-5 (restore) self-check — no XCTest, no Xcode project. `PremiumService` names `Adapty`
# directly, so it gets a stub module compiled first and linked in its place, same trick as
# `premium-barrier-check.sh`.
#
# Rewritten 2026-09-16: `StoreKitService` is native StoreKit 2 (sealed `Product`/`Transaction`, no
# public initializer), so it can no longer be driven by a stub the way `SwiftyStoreKit` was. This
# check now goes through the facade with a mocked `AppleSubscribing` only, and no longer compiles
# `StoreKitService.swift` itself — see the header of `PremiumStoreKitCheck.swift`. `PriceCache.swift`
# is required because `PremiumService.swift` names the type in its own init default.
#
# Mechanical PM-08 row 8 check, folded in here rather than a Swift test: the kit must never call
# `Transaction.finish()`, run its own `Transaction.updates` listener, or sweep `Transaction.unfinished`
# — Adapty (full mode) is the only finisher. Several doc comments across `Sources/` name these three
# on purpose, to state the rule where a reader would look for it (StoreKitService.swift's header,
# AdaptyService.swift's `onUnfinishedTransaction`) — those are expected and excluded. What must stay
# at zero is a REAL line of code touching any of the three: comment lines (`//` after trimming
# leading whitespace) do not count.
#
# This check does not stop at the first failing row — it runs every row, collects every failure, and
# exits non-zero if any row failed.
set -e
cd "$(dirname "$0")/.."

finish_calls=$(grep -rn -E 'Transaction\.(finish|updates|unfinished)' Sources | grep -v -E ':[[:space:]]*//' | wc -l | tr -d ' ') || true
if [ "$finish_calls" -ne 0 ]; then
	echo "PM-08 row 8: expected 0 real calls to Transaction.finish/updates/unfinished in Sources/, found $finish_calls"
	grep -rn -E 'Transaction\.(finish|updates|unfinished)' Sources | grep -v -E ':[[:space:]]*//'
	exit 1
fi
echo "PM-08 row 8: 0 real calls to Transaction.finish/updates/unfinished in Sources/ — OK"

work="${TMPDIR:-/tmp}/premium-storekit-check"
rm -rf "$work"
mkdir -p "$work"
swiftc -emit-module -emit-library -static \
	-module-name Adapty \
	-emit-module-path "$work/Adapty.swiftmodule" \
	-o "$work/libAdapty.a" \
	Checks/Stubs/Adapty/AdaptyProfile.swift
swiftc -o "$work/check" -I "$work" -L "$work" -lAdapty \
	Checks/Cases/PremiumStoreKitCheck.swift \
	Sources/IntegrationKit/Support/LogLevel.swift \
	Sources/IntegrationKit/Support/DebugLog.swift \
	Sources/IntegrationKit/Support/ConfigurationIssues.swift \
	Sources/IntegrationKit/Support/SingleResume.swift \
	Sources/IntegrationKit/Support/WithTimeout.swift \
	Sources/IntegrationKit/Premium/PremiumService.swift \
	Sources/IntegrationKit/Premium/Protocols/PremiumServicing.swift \
	Sources/IntegrationKit/Premium/Protocols/AdaptyPremiumProviding.swift \
	Sources/IntegrationKit/Adapty/PurchaseVerdict.swift \
	Sources/IntegrationKit/Adapty/AdaptyProductsAnswer.swift \
	Sources/IntegrationKit/Premium/Models/PaywallState.swift \
	Sources/IntegrationKit/Premium/Models/RemoteValue.swift \
	Sources/IntegrationKit/Premium/Protocols/AppleSubscribing.swift \
	Sources/IntegrationKit/Premium/Protocols/PremiumStateStoring.swift \
	Sources/IntegrationKit/Premium/Models/PremiumState.swift \
	Sources/IntegrationKit/Premium/Models/ReceiptAnswer.swift \
	Sources/IntegrationKit/Premium/Models/PremiumSource.swift \
	Sources/IntegrationKit/Premium/Models/PremiumAccess.swift \
	Sources/IntegrationKit/Premium/Models/PremiumAccess+Adapty.swift \
	Sources/IntegrationKit/Premium/Models/PremiumProduct.swift \
	Sources/IntegrationKit/Premium/Models/PremiumPeriod.swift \
	Sources/IntegrationKit/Premium/Models/PremiumOffer.swift \
	Sources/IntegrationKit/Premium/Models/PurchaseOutcome.swift \
	Sources/IntegrationKit/Premium/Models/RestoreOutcome.swift \
	Sources/IntegrationKit/Premium/Models/PremiumNotification.swift \
	Sources/IntegrationKit/Premium/Helpers/PremiumResolver.swift \
	Sources/IntegrationKit/Premium/Helpers/PriceCache.swift \
	Sources/IntegrationKit/Premium/Helpers/UserDefaultsPremiumStore.swift
exec "$work/check"
