# IntegrationKit

A Swift Package that wraps five third-party SDKs behind one small public surface:
**Firebase** (Core + Crashlytics + Remote Config), **Amplitude**, **Adapty** (premium/paywalls),
**AppsFlyer** (attribution, deep links) and **SwiftyStoreKit** (receipt, restore,
prices). The package owns the wiring and the premium arbitration between Adapty
and Apple's own receipt; the app supplies keys, event names, placements, its App
Store shared secret and its product ids — no StoreKit code of its own.

Only four protocols and a handful of models are public — everything else (Adapty,
AppsFlyer, and the concrete services behind them) is an internal implementation
detail. The full walkthrough — every `configure` parameter, paywall flow, deep
links, troubleshooting — lives in [`docs/Integration.md`](docs/Integration.md).
This file is the short version.

## Requirements

- iOS 15.6+
- **Xcode 26.0+** — not this package's own floor, but a hard one all the same.
  Adapty 4.1.3's manifest declares `swift-tools-version: 6.2` and uses package
  traits, so SwiftPM older than 6.1 cannot parse it and resolution fails before
  anything is compiled. This package's manifest stays at
  `swift-tools-version: 5.9`; the requirement arrives through the dependency
  graph, and there is nothing here to lower it with.

Staying on an older Xcode means staying on IntegrationKit 0.2.2, which pins
Adapty 2.10.x.

## Installation

```swift
.package(url: "https://github.com/GoodwinNick/IntegrationKit", from: "0.3.0")
```

In Xcode: File → Add Package Dependencies → the same URL, product `IntegrationKit`.

## Quick start

```swift
import IntegrationKit

// Call before IntegrationKit.configure(...).
FirebaseIntegration.configure(isDebug: isDebug)

let kit = IntegrationKit.configure(
	deviceId: deviceId,
	amplitudeKey: amplitudeApiKey,
	adaptyKey: adaptyApiKey,
	placements: ["main", "onboarding"],
	sessionsCounter: sessionsCounter,
	sharedSecret: appStoreSharedSecret,
	productIds: ["year.sub", "week.sub"],
	isDebug: isDebug,
	isTestsRunning: isTestsRunning,
	levels: ["premium"],
	firstOpenEvent: "first_open",
	appsFlyerDevKey: appsFlyerDevKey,
	appsFlyerAppId: appsFlyerAppId,
	remoteConfigDefaults: ["paywallReview": NSNumber(value: false)]
)

kit.analytics.logEvent("app_open")
kit.crashes.recordNonFatal("launch", someError)
// Answers the default above until the Firebase fetch lands — never blocks.
if kit.remoteConfig.bool("paywallReview") { showReviewPaywall() }

// Premium is announced, not polled: the notification fires only when the flag
// actually changes, and `kit.premium.isPremium` is the new value.
NotificationCenter.default.addObserver(
	forName: .premiumDidChange,
	object: nil,
	queue: .main
) { _ in
	render(isPremium: kit.premium.isPremium)
}
```

`.premiumDidChange` is the only way to observe premium. The value moves without
the app asking — Adapty pushes a new profile, an interrupted purchase is
delivered by the payment queue at launch — so a screen that reads `isPremium`
once and never subscribes goes stale.

**Store the returned `IntegrationKit` for the lifetime of the app** — on the
`AppDelegate`, not in a local that ends with the function: pulling one member
out of it (`let premium = IntegrationKit.configure(...).premium`) drops the
struct, and the paywall retries, AppsFlyer attribution, the deep-link forwards
and the diagnostics go with it, silently. See
[`docs/Integration.md`](docs/Integration.md#6-call-firebaseintegrationconfigureisdebug-then-integrationkitconfigure)
for what each of those costs.

`isDebug` and `isTestsRunning` are the package's only two switches, and the app
computes both: `isDebug` is its own `#if DEBUG`, `isTestsRunning` is
`ProcessInfo.processInfo.arguments.contains("-uitest")` or
`ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil`.
Neither has a default — the package does not guess the build type or the kind
of launch. `isDebug` decides Crashlytics collection (on exactly when it is
`false`, so a debug build can still be made to report a live crash) and
AppsFlyer's console logging. `isTestsRunning` leaves Amplitude, Adapty and
AppsFlyer down for the whole run, so a test run cannot poison the analytics or
spend the attribution budget it is measured by; Firebase and StoreKit are not
touched by it, because a run meant to catch crashes must not lose them. They
are separate keys on purpose: one silences, the other reports.

An empty key switches its SDK off for the whole run rather than half-starting
it — `adaptyKey: ""` leaves the Adapty layer inert and records why,
`amplitudeKey: ""` sends no events, `appsFlyerDevKey: ""` creates no AppsFlyer
at all. No `#if` needed for a build flavour without one of them; for a test run
pass `isTestsRunning: true` instead, which reaches the same three states with
the real reason recorded rather than a fake key.

Every such cause lands in `kit.configurationIssues` — a plain `[String]`, one
line per cause, readable in a **release** build. It is the answer to "the SDK is
silent and I cannot tell whether it is off on purpose":

```swift
kit.configurationIssues.forEach { print("[IntegrationKit] \($0)") }
```

`kit.premium`, `kit.analytics`, `kit.crashes`, `kit.remoteConfig` are the only
surfaces the app talks to afterwards — `PremiumServicing`, `AnalyticsTracking`,
`CrashReporting`, `RemoteConfigServicing`. `kit.remoteConfig` reads Firebase
Remote Config by the app's own keys — `bool`, `string`, `int`, `double`, each
answering the default registered in `remoteConfigDefaults` until the fetch
lands. The package names no key of its own, and a key with no default reads as
the type's zero, which no caller can tell apart from a fetched value: register
a default for every key you read.
Besides `logEvent`, `kit.analytics` carries `setUserId(_:)` (re-point analytics
at another id after a login) and `deviceId` (Amplitude's own id, `nil` until the
layer is up). Deep links go through `kit.handleContinue(...)` /
`kit.handleOpen(...)`, and the ATT answer through
`kit.updateTrackingAuthorization(_:)`. One more forward reaches Adapty
directly, and beside it sits the one call that no longer reaches anything:

```swift
// The app's own profile attributes. `lastUsedDay`, `launchSession`,
// `deep_link_value` and `purchasePlace` the package writes itself — do not
// write those from the app, it only doubles the traffic.
kit.setProfileValue(value: "returning_user", key: "cohort")

// Deprecated and does nothing since 0.3.0: Adapty 4.x deleted onboarding
// reporting. Delete the call and log onboarding steps through analytics.
kit.logOnboardingOpen(step: 1)
```

See
[`docs/Integration.md`](docs/Integration.md) for the full `AppDelegate`, the
meaning of every `configure` parameter and the paywall-to-purchase flow.

## What stays in your app

- SDK keys (Amplitude, Adapty, AppsFlyer dev key) — obtained from each
  dashboard; obfuscated keys are decoded with `ObfuscatedSecret.reveal` before
  being passed in.
- `deviceId` — one stable id shared across Amplitude, Adapty and AppsFlyer.
- Event names and analytics properties — the package takes plain `String`, it
  does not define an event enum.
- Remote Config keys and their defaults — passed as `remoteConfigDefaults`, read
  back by the same key. The package defines none.
- `GoogleService-Info.plist`, the Crashlytics dSYM Run Script, ATT usage string
  and Associated Domains — everything Xcode-project-side.
- The App Store shared secret and the product ids to look for in the receipt —
  passed to `configure`, never hardcoded in the package. StoreKit itself is the
  package's job now: receipt validation, restore, the fallback purchase and the
  prices shown on the paywall all live inside it.
- `isDebug` and `isTestsRunning` — the app's own `#if DEBUG` and its own reading
  of `-uitest` / `XCTestConfigurationFilePath`. The package never derives either.
- Calling `FirebaseIntegration.configure(isDebug:)` and
  `IntegrationKit.configure(...)` at app launch, and forwarding
  `application(_:continue:restorationHandler:)` /
  `application(_:open:options:)` through `kit.handleContinue` / `kit.handleOpen`.

## Package layout

```
Sources/IntegrationKit/
├── Firebase/     Core + Crashlytics + Remote Config, FirebaseIntegration,
│                 CrashReporting, RemoteConfigServicing
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

`Checks/` has twelve self-checks. Eleven compile the real source files with
`swiftc` against stub SDK modules — no Xcode, no XCTest, no network, no real
SDK linked; `integration-kit-check.sh` is the one of those eleven that also
*runs* the composition root, the way an app does. The twelfth,
`buildhost-check.sh`, runs the `BuildHost` build above, because the other
eleven never link a real SDK:

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
