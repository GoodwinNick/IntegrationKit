#!/bin/sh
# Pins the two guards from the PremiumService risk table: PM-01 row 4 (`start()` idempotency) and
# PM-04 row 7 (no concurrent `purchase()`). Written red before the guards existed, green since they
# landed in `Sources/PremiumService.swift` — a failure here means one of the two was lost.
#
# Same trick as `premium-barrier-check.sh`: `PremiumService` names exactly one Adapty type
# (`AdaptyProfile`), so a stub module called `Adapty` is compiled first and linked in its place.
set -e
cd "$(dirname "$0")/.."
work="${TMPDIR:-/tmp}/premium-pending-check"
rm -rf "$work"
mkdir -p "$work"
swiftc -emit-module -emit-library -static \
	-module-name Adapty \
	-emit-module-path "$work/Adapty.swiftmodule" \
	-o "$work/libAdapty.a" \
	Checks/Stubs/AdaptyProfile.swift
swiftc -o "$work/check" -I "$work" -L "$work" -lAdapty \
	Checks/PremiumPendingCheck.swift \
	Sources/IntegrationKit/Support/DebugLog.swift \
	Sources/IntegrationKit/Support/SingleResume.swift \
	Sources/IntegrationKit/Support/WithTimeout.swift \
	Sources/IntegrationKit/Premium/PremiumService.swift \
	Sources/IntegrationKit/Premium/Protocols/PremiumServicing.swift \
	Sources/IntegrationKit/Premium/Protocols/AdaptyPremiumProviding.swift \
	Sources/IntegrationKit/Adapty/AdaptyPurchaseResult.swift \
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
	Sources/IntegrationKit/Premium/Helpers/UserDefaultsPremiumStore.swift
exec "$work/check"
