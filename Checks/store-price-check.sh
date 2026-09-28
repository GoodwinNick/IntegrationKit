#!/bin/sh
# PM-07 row 17 self-check — pure Decimal/Foundation, no StoreKit or Adapty stub needed.
set -e
cd "$(dirname "$0")/.."

out="${TMPDIR:-/tmp}/store-price-check"
swiftc -o "$out" \
	Checks/Cases/StorePriceCheck.swift \
	Sources/IntegrationKit/Premium/Helpers/StorePrice.swift

if "$out"; then
	status=0
else
	status=$?
fi

# Mechanical check: both product price paths (direct StoreKit + Adapty's wrapped skProduct) and
# both offer price paths must route through StorePrice.corrected, not read `.price` raw.
wiring_failed=0
for file in \
	Sources/IntegrationKit/Premium/Models/PremiumProduct+StoreKit.swift \
	Sources/IntegrationKit/Premium/Models/PremiumProduct+Adapty.swift \
	Sources/IntegrationKit/Premium/Models/PremiumOffer+StoreKit.swift \
	Sources/IntegrationKit/Premium/Models/PremiumOffer+Adapty.swift
do
	count=$(grep -c 'StorePrice\.corrected(' "$file") || true
	if [ "$count" -lt 1 ]; then
		echo "row 17 wiring: $file does not call StorePrice.corrected"
		wiring_failed=1
	fi
done
if [ "$wiring_failed" -eq 0 ]; then
	echo "row 17 wiring: all four price paths call StorePrice.corrected — OK"
fi

if [ "$status" -ne 0 ] || [ "$wiring_failed" -ne 0 ]; then
	exit 1
fi
