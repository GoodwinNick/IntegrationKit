# IntegrationKit

A Swift Package that wraps five third-party SDKs behind one small public surface:
**Firebase** (Core + Crashlytics), **Amplitude**, **Adapty** (premium/paywalls),
**AppsFlyer** (attribution, deep links) and **SwiftyStoreKit** (receipt, restore,
prices). The package owns the wiring and the premium arbitration between Adapty
and Apple's own receipt; the app supplies keys, event names, placements, its App
Store shared secret and its product ids — no StoreKit code of its own.

Only three protocols and a handful of models are public — everything else (Adapty,
AppsFlyer, and the concrete services behind them) is an internal implementation
detail. The full walkthrough — every `configure` parameter, paywall flow, deep
links, troubleshooting — lives in [`docs/Integration.md`](docs/Integration.md).
This file is the short version.

## Requirements

- iOS 15.6+
- Swift 5.9 (`swift-tools-version: 5.9`)

## Installation

```swift
.package(url: "https://github.com/GoodwinNick/IntegrationKit", from: "0.2.0")
```

In Xcode: File → Add Package Dependencies → the same URL, product `IntegrationKit`.

## Quick start

```swift
import IntegrationKit

// Call before IntegrationKit.configure(...).
FirebaseIntegration.configure()

let kit = IntegrationKit.configure(
	deviceId: deviceId,
	amplitudeKey: amplitudeApiKey,
	adaptyKey: adaptyApiKey,
	placements: ["main", "onboarding"],
	sessionsCounter: sessionsCounter,
	sharedSecret: appStoreSharedSecret,
	productIds: ["year.sub", "week.sub"],
	levels: ["premium"],
	firstOpenEvent: "first_open",
	appsFlyerDevKey: appsFlyerDevKey,
	appsFlyerAppId: appsFlyerAppId
)

kit.analytics.logEvent("app_open")
kit.crashes.recordNonFatal("launch", someError)
```

An empty key switches its SDK off for the whole run rather than half-starting
it — `adaptyKey: ""` leaves the Adapty layer inert and records why,
`amplitudeKey: ""` sends no events, `appsFlyerDevKey: ""` creates no AppsFlyer
at all. No `#if` needed for a test run or a build flavour without one of them.

`kit.premium`, `kit.analytics`, `kit.crashes` are the only surfaces the app talks
to afterwards — `PremiumServicing`, `AnalyticsTracking`, `CrashReporting`. Deep
links go through `kit.handleContinue(...)` / `kit.handleOpen(...)`, and the ATT
answer through `kit.updateTrackingAuthorization(_:)`. See
[`docs/Integration.md`](docs/Integration.md) for the full `AppDelegate`, the
meaning of every `configure` parameter and the paywall-to-purchase flow.

## What stays in your app

- SDK keys (Amplitude, Adapty, AppsFlyer dev key) — obtained from each
  dashboard; obfuscated keys are decoded with `ObfuscatedSecret.reveal` before
  being passed in.
- `deviceId` — one stable id shared across Amplitude, Adapty and AppsFlyer.
- Event names and analytics properties — the package takes plain `String`, it
  does not define an event enum.
- `GoogleService-Info.plist`, the Crashlytics dSYM Run Script, ATT usage string
  and Associated Domains — everything Xcode-project-side.
- The App Store shared secret and the product ids to look for in the receipt —
  passed to `configure`, never hardcoded in the package. StoreKit itself is the
  package's job now: receipt validation, restore, the fallback purchase and the
  prices shown on the paywall all live inside it.
- Calling `FirebaseIntegration.configure()` and `IntegrationKit.configure(...)`
  at app launch, and forwarding `application(_:continue:restorationHandler:)` /
  `application(_:open:options:)` through `kit.handleContinue` / `kit.handleOpen`.

## Package layout

```
Sources/IntegrationKit/
├── Firebase/     Core + Crashlytics, FirebaseIntegration, CrashReporting
├── Amplitude/    analytics facade, IDFA plugin, AnalyticsTracking
├── Adapty/       activation, paywalls, purchases (internal)
├── AppsFlyer/    ATT, deep links, attribution (internal)
├── StoreKit/     receipt, restore, purchase, prices via SwiftyStoreKit (internal)
├── Premium/      Adapty/Apple arbitration behind PremiumServicing
└── Support/      composition-root helpers (obfuscated secrets, timeouts, debug log)
```

`IntegrationKit.swift` at the top of `Sources/IntegrationKit/` is the
composition root — the one place that builds and wires all of the above.

## Building and checks

The package does not build on its own (`swift build` targets the macOS host and
fails on the iOS-only dependencies). `BuildHost/` is a minimal iOS app on
xcodegen that links the package and proves the public API is enough:

```bash
cd BuildHost && xcb app-sim
```

`Checks/` has ten self-checks that compile the real source files with `swiftc`
against stub SDK modules — no Xcode, no XCTest, no network, no real SDK linked:

```bash
for s in Checks/*.sh; do "./$s"; done
```

Every assert comes from a row of an approved risk table and names the exact
value that row names. Tests are written before the code that satisfies them, so
a red assert is a specification not yet met — each names its row. See
[`docs/Integration.md`](docs/Integration.md#building-and-checks) for what each
script pins down.

## License

MIT (c) 2026 Yevhenii Petrenko — [LICENSE](LICENSE).
