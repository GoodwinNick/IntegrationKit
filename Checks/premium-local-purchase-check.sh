#!/bin/sh
# Local-purchase mark self-check — written as the spec for behaviour that did not exist yet, green
# since it landed. No XCTest, no Xcode project. Same trick as `premium-barrier-check.sh`:
# `PremiumService` names exactly one Adapty type (`AdaptyProfile`), so a stub module called `Adapty`
# is compiled first and linked in its place.
#
# A non-zero exit is a regression, not the expected outcome.
set -e
cd "$(dirname "$0")/.."
work="${TMPDIR:-/tmp}/premium-local-purchase-check"
rm -rf "$work"
mkdir -p "$work"
swiftc -emit-module -emit-library -static \
	-module-name Adapty \
	-emit-module-path "$work/Adapty.swiftmodule" \
	-o "$work/libAdapty.a" \
	Checks/Stubs/AdaptyProfile.swift
swiftc -o "$work/check" -I "$work" -L "$work" -lAdapty \
	Checks/PremiumLocalPurchaseCheck.swift \
	Sources/IntegrationKit/Support/LogLevel.swift \
	Sources/IntegrationKit/Support/DebugLog.swift \
	Sources/IntegrationKit/Support/ConfigurationIssues.swift \
	Sources/IntegrationKit/Support/SingleResume.swift \
	Sources/IntegrationKit/Support/WithTimeout.swift \
	Sources/IntegrationKit/Premium/PremiumService.swift \
	Sources/IntegrationKit/Premium/Protocols/PremiumServicing.swift \
	Sources/IntegrationKit/Premium/Protocols/AdaptyPremiumProviding.swift \
	Sources/IntegrationKit/Adapty/AdaptyPurchaseResult.swift \
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
	Sources/IntegrationKit/Premium/Helpers/UserDefaultsPremiumStore.swift
exec "$work/check"
