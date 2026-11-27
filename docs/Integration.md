# IntegrationKit — integration guide

This is the detailed companion to the top-level [`README.md`](../README.md).
Every code sample here is checked against the actual public API — the
protocols in `Sources/IntegrationKit/*/Protocols`, the models in
`Sources/IntegrationKit/Premium/Models`, and the composition root in
`Sources/IntegrationKit/IntegrationKit.swift`. Where a step is a fact about
the Xcode project rather than the package's Swift API (plist keys, Run Script,
capabilities), it is called out as such.

`BuildHost/Sources/App.swift` is the canonical example of everything in this
guide put together — a build host that never runs, only compiles, so the
compiler proves the public API is enough on its own.

## Contents

- [Setup from scratch](#setup-from-scratch)
- [`IntegrationKit.configure`](#integrationkitconfigure)
- [Remote config](#remote-config)
- [Analytics](#analytics)
  - [Firebase Analytics](#firebase-analytics)
- [Crash reporting](#crash-reporting)
- [Premium](#premium)
  - [Active subscriptions](#active-subscriptions)
  - [Promoted purchases](#promoted-purchases)
- [The StoreKit side](#the-storekit-side)
- [Deep links](#deep-links)
- [Building and checks](#building-and-checks)
- [DEBUG logs](#debug-logs)
- [Troubleshooting](#troubleshooting)
- [Readiness checklist](#readiness-checklist)

## Setup from scratch

### 1. Add the package

Xcode → File → Add Package Dependencies → this repo's URL → product
`IntegrationKit`.

```swift
.package(url: "https://github.com/GoodwinNick/IntegrationKit", from: "0.5.0")
```

The target's minimum deployment target must be iOS 15.6 or the package will
not build.

**Xcode 26.0 or newer is required, and the requirement is not this package's.**
Since 0.3.0 the Adapty dependency is 4.1.3, whose own manifest declares
`swift-tools-version: 6.2` and uses package traits — a feature SwiftPM only
learned in 6.1. An older SwiftPM cannot parse that manifest at all, so
resolution fails before a single file is compiled, with an error about the
manifest rather than about anything in your app. This package's manifest stays
at `swift-tools-version: 5.9` and its own floor has not moved; the requirement
arrives through the dependency graph, and there is nothing here that can lower
it. An app that has to stay on an older Xcode stays on IntegrationKit 0.2.2,
which pins Adapty 2.10.x.

### Upgrading from 0.10.x

Nothing breaks, and nothing changes for an app that does not pass the new map.

| What | Then (0.10.x) | Now (0.11.0) |
|---|---|---|
| `PremiumServicing.hasAccess(level:)` | — | New member **with** a default implementation that answers `isPremium`, so an app's own fake keeps compiling. See [Access per level](#access-per-level). |
| `IntegrationKit.configure(productLevels:)` | — | New argument, defaults to `[:]` — the single verdict of 0.10.x, with nothing new computed, stored or posted. |
| `-grantLevel <levelId>` | — | New repeatable test-mode flag: the access levels a fake Adapty grant carries. Nothing changes for a run that does not pass it. |

### Upgrading from 0.9.x

Nothing breaks at a call site that only uses `kit.premium`. One thing breaks the
build of an app that **implements** `PremiumServicing` itself — in practice the
fake in its unit tests.

| What | Then (0.9.x) | Now (0.10.0) |
|---|---|---|
| `PremiumServicing.activeSubscriptionIds(completion:)` | — | New member with **no default implementation**, on purpose: a fake that does not answer it fails to compile instead of silently reading as "no subscriptions". `PremiumService` is the only conformer in the package. See [Active subscriptions](#active-subscriptions). |
| `-activeSubscription <productId>` | — | New repeatable test-mode flag for the fake Adapty's active subscriptions. Nothing changes for a run that does not pass it. |

### Upgrading from 0.2.x

Four things change at the call site or in behaviour. Everything else in this
guide is the same as it was.

| What | Then (0.2.x) | Now (0.3.0) |
|---|---|---|
| `kit.logOnboardingOpen(step:)` | Reported an onboarding screen to Adapty | Deprecated and empty. Adapty 4.x deleted `logShowOnboarding` — delete the call, and see [`logOnboardingOpen`](#the-facades-own-api) for where onboarding funnels go instead. |
| A purchase Adapty could not confirm | `.pending`, **with premium granted** | `.failed`, with nothing granted. See [Purchase outcomes](#models) — this is the one change that can move money, and it moves it in the app's favour, not against a paying user. |
| Paywall remote config | One config per placement | One per **locale**. The package picks the device's; `remoteValue` is unchanged at the call site. |
| App Store promoted purchases | Bought automatically by Adapty's default delegate | Refused, with a log line. See [Promoted purchases](#promoted-purchases). |

The rest is source-compatible: no protocol the app implements changed, and no
public model lost a case.

### Upgrading from 0.7.x

Nothing breaks at the call site. Three things change in behaviour, and one needs
a build setting.

| What | Then (0.7.x) | Now (0.8.0) |
|---|---|---|
| Firebase Analytics | Not linked; an app that wanted it added `FirebaseAnalytics` itself and called `Analytics.logEvent` | The package links the full `FirebaseAnalytics` product and mirrors every event, user property and user id to it, and logs every successful purchase with `Analytics.logTransaction`. Replace the app's own `Analytics.logEvent` calls with `kit.analytics.logEvent` — see [Firebase Analytics](#firebase-analytics). |
| `setFirebaseAppInstanceId` | The app read `Analytics.appInstanceID()` and passed it in | The package does it. The call can be deleted; keeping it is harmless. |
| `isTestsRunning: true` | Firebase untouched | Firebase Analytics receives nothing and has collection switched off. Crash collection is unchanged. |
| Linker flags | — | Add `-ObjC` to Other Linker Flags. |

The `FirebaseAnalytics` product pulls in IDFA support and Google's on-device
conversion measurement, and this changes what the app tells App Store Connect
about the data it collects — that is an app-side declaration the package cannot
make and this guide has not verified.

### Upgrading from 0.6.x

One thing changes at the call site.

| What | Then (0.6.x) | Now (0.7.0) |
|---|---|---|
| `IntegrationKit.configure(..., sharedSecret:, ...)` | An App Store Connect shared secret, used to validate the receipt over the network | **Parameter removed, no default.** StoreKit 2 validates `Transaction.currentEntitlements` locally and cryptographically — there is no shared secret to configure and no server round trip to turn off. Delete the argument at the call site or the build fails. |

The engine underneath changed too — SwiftyStoreKit is gone, native StoreKit 2
runs the receipt check, restore and fallback purchase; see
[The StoreKit side](#the-storekit-side) for what that means for behaviour.
Nothing else at the call site moved: `productIds`, `purchase`, `restore` and
every other `PremiumServicing` member are unchanged.

### 2. Add `GoogleService-Info.plist`

Your own Firebase project's config file (Firebase console), dropped into the
target's root with **target membership checked**. Without it,
`FirebaseIntegration.configure(isDebug:)` calls `FirebaseApp.configure()`,
which fails fatally at launch — there is no soft-fail path.

### 3. `Info.plist` / build settings

None of these are set by the package — all of them are app-side (modern Xcode
keeps them as `INFOPLIST_KEY_*` build settings rather than literal
`Info.plist` rows):

| Key | Why | Used by |
|---|---|---|
| `NSUserTrackingUsageDescription` | Required for the ATT dialog — without it `ATTrackingManager.requestTrackingAuthorization` shows nothing | ATT / AppsFlyer / Amplitude IDFA |
| `-ObjC` in Other Linker Flags (`OTHER_LDFLAGS`) | Firebase's own guide says Analytics requires it; see [Firebase Analytics](#firebase-analytics) for why the package cannot set it | Firebase Analytics |

### 4. Capabilities

- **Associated Domains** — only if the app accepts Universal Links through an
  AppsFlyer OneLink (`applinks:<app>.onelink.me` or a custom domain). Without
  it, iOS never calls `application(_:continue:restorationHandler:)` at all.
- A URL scheme for legacy deep links — standard `CFBundleURLTypes` in
  `Info.plist` (Xcode → target → Info → URL Types), independent of the
  package.

### 5. Run Script — dSYM upload for Crashlytics

Required for Crashlytics, otherwise crashes show up unsymbolicated in the
dashboard. Add a Run Script build phase after "Compile Sources":

**Input Files:**
```
${DWARF_DSYM_FOLDER_PATH}/${DWARF_DSYM_FILE_NAME}/Contents/Resources/DWARF/${TARGET_NAME}
$(SRCROOT)/$(BUILT_PRODUCTS_DIR)/$(INFOPLIST_PATH)
${SRCROOT}/<Target>/GoogleService-Info.plist
$(TARGET_BUILD_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)/GoogleService-Info.plist
```

**Script:**
```sh
if [ ! -f "${SRCROOT}/<Target>/GoogleService-Info.plist" ]; then
  echo "warning: GoogleService-Info.plist not found, skipping Crashlytics dSYM upload"
  exit 0
fi
SCRIPT="${BUILD_DIR%/Build/*}/SourcePackages/checkouts/firebase-ios-sdk/Crashlytics/run"
if [ -f "$SCRIPT" ]; then
  "$SCRIPT"
else
  echo "warning: Crashlytics run script not found"
fi
```

`checkouts/firebase-ios-sdk` is the SPM checkout in the **app target's** own
`SourcePackages`, not the package's — since `IntegrationKit` pulls in
`firebase-ios-sdk` transitively, it shows up there automatically once
dependencies resolve.

### 6. Privacy manifest — check `UserDefaults` is declared

App-side, and easy to miss because the package looks like it should carry its
own. It does not, on purpose: SPM consumes `IntegrationKit` as source, so its
calls compile into **your** binary, and App Store Connect's static scan
attributes them to your app. Your `PrivacyInfo.xcprivacy` is what has to cover
them.

The package's own code touches exactly one required-reason API — `UserDefaults`,
in four files:

| File | What it keeps there |
|---|---|
| `Premium/Helpers/UserDefaultsPremiumStore.swift` | the cached premium state between launches |
| `Premium/PremiumService.swift` | the legacy flag app screens still read |
| `Amplitude/AmplitudeAnalytics.swift` | the first-open gate |
| `Firebase/FirebaseIntegration.swift` | Crashlytics collection, written by the SDK under `com.crashlytics.data_collection` |

So `NSPrivacyAccessedAPITypes` needs an entry for
`NSPrivacyAccessedAPICategoryUserDefaults`. The reason code for an SDK reading
and writing its own app's defaults is normally `CA92.1` — confirm it against
Apple's current table rather than copying it blind, the list does change. Most
apps already declare this for their own code, in which case there is nothing to
add: check, do not assume.

Two things the package does *not* need declared, so you do not go looking:
it reads no file timestamps, no boot time, no disk space and no active
keyboards. The five wrapped SDKs ship their own manifests inside their
binaries.

Separately, `AmplitudeIDFAPlugin` reads the advertising identifier on every
event once ATT is authorised, which is what makes this app a tracking app —
`NSPrivacyTracking` and the tracking domains belong in the same file, and each
wrapped SDK's own documentation lists the domains it needs.

### 7. Call `FirebaseIntegration.configure(isDebug:)`, then `IntegrationKit.configure(...)`

Firebase configures first, and separately — it has no state the composition
root needs. Everything else goes through one call:

```swift
import IntegrationKit

final class AppDelegate: NSObject, UIApplicationDelegate {

	private var kit: IntegrationKit?

	func application(
		_ application: UIApplication,
		didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
	) -> Bool {
		// The package's only two switches, and both of them are facts only the app can see.
		#if DEBUG
		let isDebug = true
		#else
		let isDebug = false
		#endif
		let isTestsRunning = ProcessInfo.processInfo.arguments.contains("-uitest")
			|| ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

		// Must be first: a report filed before this line is dropped and counted.
		FirebaseIntegration.configure(isDebug: isDebug)

		let kit = IntegrationKit.configure(
			deviceId: AppDefaults.deviceId,
			amplitudeKey: ObfuscatedSecret.reveal(encrypted: SDKKeys.amplitudeEncrypted, secret: SDKKeys.secret),
			adaptyKey: ObfuscatedSecret.reveal(encrypted: SDKKeys.adaptyEncrypted, secret: SDKKeys.secret),
			placements: ["main", "onboarding"],
			sessionsCounter: AppDefaults.sessionsCounter,
			productIds: ["year.sub", "week.sub"],
			isDebug: isDebug,
			isTestsRunning: isTestsRunning,
			levels: ["premium"],
			firstOpenEvent: "first_open",
			appsFlyerDevKey: ObfuscatedSecret.reveal(encrypted: SDKKeys.appsFlyerEncrypted, secret: SDKKeys.secret),
			appsFlyerAppId: "1234567890",
			// How long the first attribution session is held waiting for the ATT answer. 60 s fits a
			// prompt shown at launch; raise it if the prompt comes after onboarding.
			attTimeout: 60,
			// Your Remote Config keys and the value each answers until the fetch lands. The
			// package defines none of its own; omit the argument if you use no remote config.
			remoteConfigDefaults: ["paywallReview": NSNumber(value: false)],
			// Straight through, untouched. A cold launch that came from a link carries it here, and
			// AppsFlyer holds the session until that link resolves only if it is handed this.
			launchOptions: launchOptions
		)
		self.kit = kit

		NotificationCenter.default.addObserver(
			forName: .premiumDidChange,
			object: nil,
			queue: .main
		) { _ in
			print("premium is now \(kit.premium.isPremium)")
		}

		kit.analytics.logEvent("app_open")
		kit.configurationIssues.forEach { print("[IntegrationKit] \($0)") }
		return true
	}

	func application(
		_ application: UIApplication,
		continue userActivity: NSUserActivity,
		restorationHandler: @escaping ([UIUserActivityRestoring]?) -> Void
	) -> Bool {
		kit?.handleContinue(userActivity, restorationHandler: restorationHandler)
		return true
	}

	func application(_ app: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
		kit?.handleOpen(url, options: options)
		return true
	}

	func application(_ application: UIApplication, open url: URL, sourceApplication: String?, annotation: Any) -> Bool {
		kit?.handleOpen(url, sourceApplication: sourceApplication, annotation: annotation)
		return true
	}
}
```

**Implement both `open url` methods, not just the `options:` one.** The system
still calls the older `sourceApplication:annotation:` variant, and the SDK keeps
a separate entry point for it — an app that forwards only the `options:` one
drops those opens with nothing logged and nothing in `configurationIssues`.

**Report the ATT answer, or your installs are organic.** AppsFlyer 7.0 stopped
waiting for ATT on its own — its `waitForATTUserAuthorization` is deprecated
with "the SDK no longer manages ATT timing internally", and ATT is explicitly
not one of the conditions its session-readiness listener waits for. So the wait
belongs to this package now, and the thing it waits for is your call:

```swift
ATTrackingManager.requestTrackingAuthorization { [weak self] status in
    // Whatever the answer is. The value is not what matters — the dialog being
    // over is, because that is when the IDFA either exists or never will.
    self?.kit?.updateTrackingAuthorization(status)
}
```

Skip it and the first session goes out after `attTimeout` with no IDFA. A click
that can only be matched by one — anything coming through Google Ads, most
paid networks — is then matched to nobody, and the install lands in the
dashboard as organic. The symptom is indistinguishable from a broken key, which
is why this is worth saying twice.

**The `private var kit` above is a requirement, not a style choice — keep the
returned value for as long as the app runs.** `IntegrationKit` is a struct,
and the things the package cannot reach on its own are stored inside it. Write
`let premium = IntegrationKit.configure(...).premium` and the struct dies at
the end of that line, taking with it:

- **AppsFlyer — attribution, sessions and deep links.** The struct holds the
  only strong reference to the attribution service. `AppsFlyerLib` declares
  both of the properties it is handed to as `weak`
  (`@property(weak, nonatomic) id<AppsFlyerLibDelegate> delegate;` and the same
  for `deepLinkDelegate`), and the session-readiness listener it registers
  captures it weakly too. So the service deallocates, and
  from then on: no AppsFlyer session is ever started, `onConversionDataSuccess`
  has nowhere to arrive, and `didResolveDeepLink` is never called. `AppsFlyerLib`
  itself stays up and looks healthy — it just has no delegate to deliver to.
  Nothing is logged and nothing lands in `configurationIssues`.
- **Deep links and the ATT forward.** `handleContinue`, `handleOpen` and
  `updateTrackingAuthorization` are members of the struct. Without it there is
  nothing for the `AppDelegate` to forward to, so universal links and
  URL-scheme links never reach the package at all.
- **The diagnostics and the other three protocols** — `configurationIssues`,
  `droppedDeepLinks`, `analytics`, `crashes` and `remoteConfig` all hang off the
  same value.

What makes this the most expensive mistake in the guide is how much keeps
working. `premium` is fine — `PremiumService` holds Adapty itself, so
purchases, paywall state and `isPremium` behave normally. So is the paywall
retry: `NotificationCenter` keeps the block-based observer alive on its own,
whether or not anything holds the token it returns, and the block holds the
Adapty layer with it. Nothing throws, nothing is logged, `configurationIssues`
stays empty, and the only symptom is a campaign whose installs arrive
unattributed — visible weeks later, on a dashboard, as traffic that looks
organic.

`SDKKeys` and `AppDefaults` are app-side types, not part of the package — they
show where the app is expected to get its keys and stable identifiers from.
Keys arrive at `configure` as plain strings: an app that ships them obfuscated
in its binary reveals them with `ObfuscatedSecret.reveal(encrypted:secret:)`
first — the package never guesses where a key came from or how it was stored.

Everything inside `IntegrationKit.configure(...)` — Amplitude, then Adapty,
then AppsFlyer, then starting the premium arbiter — happens in one fixed
order that the app cannot reorder or skip a step of. That is the entire point
of the composition root: there is no longer a way to call `premium.start()`
late, or configure AppsFlyer before Adapty exists to receive its attribution.

**The two keys are computed by the app, every launch, and passed to both
calls.** The package never derives either of them: it cannot tell a
developer's own run from a CI machine, and an `#if DEBUG` compiled into a
package cannot be switched off by whoever needs it off. Neither key has a
default, so a build that forgets one does not compile.

`isDebug` is the app's own `#if DEBUG`, nothing more. `isTestsRunning` is the
app's reading of its own launch — the two conditions above cover both test
harnesses: XCUITest passes launch arguments, so a UI test adds `-uitest` to
`app.launchArguments`, and XCTest puts `XCTestConfigurationFilePath` into the
environment of a unit-test run by itself. Compute it once and keep it, rather
than re-reading `ProcessInfo` in several places:

```swift
enum AppRun {
	static let isTests = ProcessInfo.processInfo.arguments.contains("-uitest")
		|| ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
}
```

They are two axes, not one switch with two names, and collapsing them breaks
in both directions: a test run that also stopped crash collection would lose
exactly the crashes the run existed to find, and a debug build that also
silenced analytics would leave every development session unmeasurable.

## `IntegrationKit.configure`

```swift
public static func configure(
	deviceId: String,
	amplitudeKey: String,
	adaptyKey: String,
	placements: [String],
	sessionsCounter: Int,
	productIds: Set<String>,
	isDebug: Bool,
	isTestsRunning: Bool,
	levels: Set<String> = ["premium"],
	productLevels: [String: String] = [:],   // since 0.11.0
	firstOpenEvent: String? = nil,
	appsFlyerDevKey: String = "",
	appsFlyerAppId: String = "",
	sourceTimeout: TimeInterval = 5,
	attTimeout: TimeInterval = 60,
	adaptyAttributionEnabled: Bool = false
) -> IntegrationKit
```

| Parameter | What it is | Where it comes from | If you don't pass it |
|---|---|---|---|
| `deviceId` | One stable id, shared by Amplitude, Adapty and AppsFlyer so all three describe the same user | An app-generated/stored UUID, stable across launches | Required — no default. Amplitude, Adapty and AppsFlyer end up describing different users. |
| `amplitudeKey` | Amplitude project API key | Amplitude dashboard, per app | Required — no default. Amplitude never activates. |
| `adaptyKey` | Adapty public SDK key (`public_live_...`) | Adapty dashboard, per app | Required — no default, but `""` is legal and makes the whole Adapty layer **inert** for the run (see below). Premium can then only come from the App Store receipt. |
| `placements` | Adapty placement ids to preload paywalls/products for | Adapty dashboard, per app | An empty array means no placement is warmed up — `hasPaywall`/`products` for any placement return empty until Adapty is asked directly through a refresh. |
| `sessionsCounter` | The app's own session counter, incremented once per launch before this call | App-owned persistent counter | Required — no default. Written into the Adapty profile as-is; passing a stale or constant value just means that field in the profile stops being meaningful. |
| `productIds` | The subscription product ids to look for among current entitlements, and the ids whose prices are read from the store | App Store Connect, same ids as in the Adapty dashboard | Required — no default. An empty set means nothing is ever found among current entitlements, so Apple can never confirm premium. |
| `isDebug` | The app's own `#if DEBUG`, and the only thing that decides crash collection. Here it also turns AppsFlyer's own console logging on and off; pass the same value to `FirebaseIntegration.configure(isDebug:)` | An `#if DEBUG` in the app, beside its other developer flags | Required — no default, deliberately: a default is the package guessing the build type. `true` switches Crashlytics collection off and AppsFlyer's SDK logging on; `false` does the opposite. It does **not** touch Amplitude, Adapty or StoreKit. |
| `isTestsRunning` | Whether this launch is a test run. `true` leaves Amplitude, Adapty and AppsFlyer down for the whole run, each recording its own reason in `configurationIssues` | The app: `ProcessInfo.processInfo.arguments.contains("-uitest")` or `ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil` | Required — no default. `true` means no Amplitude events, no Adapty activation (so no live paywalls and no live purchases through it), and no AppsFlyer sessions, install data or deep links. Firebase Analytics receives nothing and has its collection switched **off**; Firebase crash collection is **not** affected — it follows `isDebug` alone. StoreKit is not built at all (since 0.6.0): the test mode's fake store answers instead, so a test run touches no payment queue, reads no receipt and shows no system dialog. |
| `levels` | The set of Adapty access level ids that count as "premium" | Adapty dashboard — access level ids configured for the paywall | Defaults to `["premium"]`. Wrong values here mean a real Adapty premium purchase never flips `isPremium` to true. |
| `productLevels` | Store product id → the access level it unlocks, for an app that sells more than one level and reads `hasAccess(level:)` | Adapty dashboard — which product is attached to which access level | Defaults to `[:]`: one verdict for every level, exactly as before 0.11.0. Every level in it must be in `levels` and every product in `productIds`; each mismatch is one line in `configurationIssues`. See [Access per level](#access-per-level). |
| `firstOpenEvent` | Analytics event name logged exactly once per install | App's own event naming | `nil` (default) — no first-open event is logged at all. |
| `appsFlyerDevKey` | AppsFlyer dev key | AppsFlyer dashboard, per app | Defaults to `""`. An empty dev key means **AppsFlyer is not created at all** — no attribution and no deep links, and one line saying so lands in `configurationIssues`. Keep forwarding `handleContinue`/`handleOpen` anyway: `handleContinue` still calls your `restorationHandler` (see [Deep links](#deep-links)), so the app must not answer UIKit itself. |
| `appsFlyerAppId` | Numeric App Store id | App Store Connect / `itunes.apple.com/lookup` | Defaults to `""`. Only meaningful together with a non-empty `appsFlyerDevKey`; without a confirmed App ID, AppsFlyer attribution can end up pointed at the wrong app. |
| `sourceTimeout` | How long one premium refresh waits for a single source — Adapty, or the Apple receipt — before deciding without it | The app's own judgement about its users' networks | Defaults to `5` seconds. That number comes from practice, not from anything Adapty documents; an app whose users are on worse networks passes a larger one instead of patching the package. Neither source answering within it is not "no premium" — it is "unknown", and the cached state stands. |
| `attTimeout` | How long AppsFlyer holds the install data waiting for the ATT answer | Where the app shows the ATT prompt | Defaults to `60` seconds, which is AppsFlyer's own recommendation for a prompt shown at launch. An app that asks after a tutorial is told to pass `120`. Only the app knows which it is, and a user who deletes the app before the limit expires stays unattributed. |
| `adaptyAttributionEnabled` | Switches on **Adapty Attribution**, Adapty's own attribution service (new in Adapty 4.x) | A decision, not a value from a dashboard — turn it on only if you intend to use Adapty's attribution instead of, or alongside, AppsFlyer's | Defaults to `false`, which is also the SDK's own default. Leave it off in an app that already runs AppsFlyer: the package forwards AppsFlyer's conversion data to the Adapty profile by hand, and switching this on adds a second, independent install signal competing with it. |

There is no separate switch for AppsFlyer's console logging any more — it is
`isDebug`, the same key crash collection runs off. AppsFlyer's docs require
the logging off in a shipping build, which a release build's `false` gives
without anyone remembering.

**An empty key makes a whole SDK inert, on purpose.** All three behave the
same way, so a build flavour without analytics or an app that ships without
one of the SDKs needs no `#if` anywhere:

| Empty argument | What happens |
|---|---|
| `adaptyKey: ""` | Adapty is never activated. Every call into the layer becomes a no-op, one line lands in `configurationIssues`, and no purchase is ever pushed through Adapty behind the app's back. |
| `amplitudeKey: ""` | Amplitude is never activated; events go nowhere. |
| `appsFlyerDevKey: ""` | No `AppsFlyerService` is created at all. `handleOpen` becomes a no-op; `handleContinue` does not — it still answers UIKit's `restorationHandler`, which is a duty the app must never take back. |

`isTestsRunning: true` reaches the same three states at once, and is the right
way to do it for a test run — an empty key would be a lie about the
configuration, and each layer records a reason of its own instead: an app
shipped without monetisation and a test run land in the same place through
different facts, and are fixed differently. Which is why they are separate
lines in `configurationIssues` rather than one.

**A test run is cleaned up after on the next live launch (since 0.9.1).** A
test run's premium layer writes into the same `UserDefaults` keys a live launch
reads — the cached verdict, the legacy flag your screens read, the per-level
verdicts (since 0.11.0), the price cache — and it has to: an app under test
reads that flag itself. So a test launch marks the device first, and the first
live launch that finds the mark wipes those keys before the premium layer is built, takes the mark down and records
one line in `configurationIssues`. The premium layer then starts free and asks
Adapty and Apple again: a real purchase comes back, a test one does not.
Without the mark nothing is touched — a device that never ran a test sees no
difference. It does not clean between two test runs (that is still your test
flags and your own reset), and it cannot fix a device that leaked before 0.9.1,
which carries no mark: reinstall the app there once.

For `adaptyKey` this is a hard guard, not a courtesy: `Adapty.activate` runs
`assert(apiKey.count >= 41 && apiKey.starts(with: "public_live"))` on the
caller's own stack, so a key that is empty — or that was obfuscated and
decrypted wrong — would take a DEBUG build down before any network call. The
package checks the shape first and records the reason instead of trapping.

The returned `IntegrationKit` exposes exactly four things to build UI on top
of: `premium: PremiumServicing`, `analytics: AnalyticsTracking`,
`crashes: CrashReporting`, `remoteConfig: RemoteConfigServicing`.
Everything AppsFlyer- or Adapty-specific
(`AdaptyService`, `AppsFlyerService`, and their internal protocols) stays
behind the facade — the app cannot reach them even by trying, since 0.2.0
they are not public types.

### The facade's own API

Nine members besides those four protocols. The first three the `AppDelegate`
calls; the middle five describe the user; the last two are diagnostics:

```swift
public func handleContinue(_ userActivity: NSUserActivity, restorationHandler: @escaping ([UIUserActivityRestoring]?) -> Void)
public func handleOpen(_ url: URL, options: [UIApplication.OpenURLOptionsKey: Any])
public func updateTrackingAuthorization(_ status: ATTrackingManager.AuthorizationStatus)

public func setUserProperty(value: String, key: String)
public func setProfileValue(value: String, key: String)
public func adaptyProfileId() async -> String?
public func setFirebaseAppInstanceId(_ id: String)
@available(*, deprecated) public func logOnboardingOpen(step: Int)

public var droppedDeepLinks: Int { get }
public var configurationIssues: [String] { get }
```

#### Where a user property lands

Three calls, three destinations. The choice is not an optimisation — it is
which dashboard can read the value afterwards:

| Call | Adapty profile | Amplitude | Use it for |
|---|---|---|---|
| `kit.setUserProperty(value:key:)` | ✅ | ✅ | An attribute both sides have to agree on — a cohort, an A/B arm, a plan name. |
| `kit.setProfileValue(value:key:)` | ✅ | — | Paywall targeting only. Every Adapty attribute is a targeting slot, and the profile holds 30. |
| `kit.analytics.setUserProperties([:])` | — | ✅ | Product analytics only, and the only one of the three that takes non-`String` values and several pairs at once. |

`setUserProperty` is the two calls above it, in that order, and nothing more —
no shared validation, no rollback. The halves fail apart on purpose: a pair
Adapty refuses (a key over 30 characters, a value over 50, the 31st attribute)
still reaches Amplitude, because Adapty's limits are Adapty's and losing the
analytics half over them would be the worse trade. Whatever Adapty refused is
in `configurationIssues`, as always.

**`setProfileValue(value:key:)`** writes one custom attribute to the Adapty
profile — the app's own, whatever the package cannot know:

```swift
kit.setProfileValue(value: "returning_user", key: "cohort")
```

The keys the package writes by itself — `lastUsedDay` and `launchSession` at
activation, `deep_link_value` when AppsFlyer resolves one, and `purchasePlace`
after every purchase that was actually paid for — do **not** need to be passed
in, and passing them again only overwrites what is already correct.

`purchasePlace` is the one to watch for if you are migrating: apps used to
write it themselves after a successful purchase. Since 0.2.2 the package does
it, because `purchase(_:placement:)` already carries the placement and is the
only place that also knows Apple took the money. It is written on a plain
Adapty purchase and on a StoreKit-fallback purchase — and on nothing else, so a
cancelled, pending or failed purchase never stamps a placement nobody paid
from.

Adapty's own rules apply and are checked before anything is sent: a key is 1…30
characters of `A-Za-z0-9._-`, a string value is 1…50 characters, and a profile
holds at most 30 non-empty attributes. A pair that breaks one of them is not
sent, and the reason — with the key and what was wrong with it — lands in
`configurationIssues`. Values that come off the network are the reason this
matters: a deep-link value simply disappears at character 51, and without the
check it would disappear silently.

**`adaptyProfileId()`** answers the Adapty profile's own id — what an app sends
to its own backend so both sides describe the same user:

```swift
if let adaptyId = await kit.adaptyProfileId() {
	try await api.link(adaptyId: adaptyId)
}
```

**`nil` means Adapty did not answer**: the layer is off, the profile has not been
created yet, or the call ran out of time. It never means "this user has no id".
Ask again later in the same run rather than storing the `nil` — an app that
writes it down once at launch turns one slow start into a permanent absence, and
that user's purchases are never joined to their account on your own backend.

**`setFirebaseAppInstanceId(_:)`** links Firebase's id for this install to the
Adapty profile, so a purchase in one dashboard can be found in the other:

**You no longer have to call it.** Since 0.8.0 the package depends on Firebase
Analytics anyway and reads `Analytics.appInstanceID()` itself — at launch, and
again on every return to the foreground until Firebase has one — and writes it
to the profile. An app that did the same by hand can delete those lines; if it
keeps them, the two writes are the same write to the same key and the later one
wins, so nothing breaks. The method stays for an app that wants to hand over an
id of its own:

```swift
if let appInstanceId = Analytics.appInstanceID() {
	kit.setFirebaseAppInstanceId(appInstanceId)
}
```

Call it whenever the id is in hand, **including before the layer has finished
starting** — a write that arrives early waits for activation instead of being
dropped, which matters because `Analytics.appInstanceID()` is usually ready
before Adapty is. The package's own read answers `nil` — and so sends nothing —
when Firebase is not up, and also when the user's consent forbids analytics
storage; both are log lines, not entries in `configurationIssues`.

Pass a real id or nothing. `Analytics.appInstanceID()` answers `nil` while
Firebase Analytics is still coming up, and unwrapping that to `""` would put a
join key on the profile that matches nothing, permanently. An empty or
whitespace-only id is refused and the reason lands in `configurationIssues`.

It goes to Adapty's integration-identifier channel (`firebase_app_instance_id`),
not into the custom attributes — so the 1…30 / 1…50 rules below do not apply to
it, and it does not count against the 30-attribute ceiling.

**`logOnboardingOpen(step:)` is deprecated since 0.3.0 and does nothing.** It
used to report one onboarding screen to Adapty as the event
`onboarding_<step>`, through `logShowOnboarding(name:screenName:screenOrder:)`.
Adapty 4.x deleted that call: onboardings there are a rendered flow of Adapty's
own, fetched with `getOnboarding` and reported by the view that draws them.
There is no longer any way to report a screen the app drew itself, and this
package draws no screens.

It is kept as an empty method rather than removed so an app on 0.2.x still
compiles against 0.3.0 and gets a warning at the call site instead of an error.
Delete the call; a later release will delete the method.

**Onboarding funnels belong in analytics** — that is where every other screen
event in an app using this package already goes, it needs no step numbering
rules, and it does not depend on an SDK's paywall model:

```swift
kit.analytics.logEvent("onboarding_step_shown", properties: ["step": 1])
```

All four Adapty forwards are no-ops when the layer is inert (`adaptyKey: ""` or
`isTestsRunning: true`), with the layer's single reason already in
`configurationIssues` — they need no `#if` or guard on the app's side.
`adaptyProfileId()` answers `nil` there, and a Firebase id handed over then is
held rather than sent, because an inert layer never activates and so never
flushes what is waiting.

## Remote config

```swift
public protocol RemoteConfigServicing: AnyObject {
	func bool(_ key: String) -> Bool
	func string(_ key: String) -> String
	func int(_ key: String) -> Int
	func double(_ key: String) -> Double
}
```

Firebase Remote Config, reached as `kit.remoteConfig`. Keys belong to the app —
the package names none — so the whole surface is "read the key I registered a
default for":

```swift
if kit.remoteConfig.bool("paywallReview") { showReviewPaywall() }
```

Defaults are registered at `configure` time and are the answer until the fetch
lands:

```swift
remoteConfigDefaults: [
	"paywallReview": NSNumber(value: false),
	"onboardingVariant": NSString(string: "control"),
]
```

`[String: NSObject]` rather than `[String: Any]` because that is what Firebase's
own `setDefaults` takes; `NSNumber` covers `bool`, `int` and `double`.

**Every read is non-blocking and always answers.** There is no "not ready"
state to handle: before the fetch lands you get your default, afterwards the
fetched value. What that costs is a race worth knowing about — a screen shown
in the first seconds of a cold launch may render the default and never
re-render. Read a remote value where the user has already spent a moment (after
a splash, on a screen reached by a tap), not in `didFinishLaunching`.

**A key with no registered default reads as `false` / `""` / `0`**, and nothing
tells that apart from a value the console actually sent. Register a default for
every key you read — it is the only guard here.

`remoteConfigTimeout` is how long the fetch waits, five seconds by default.
Firebase also throttles fetches to one per 12 hours in a release build; that
throttle is off whenever `isDebug: true`, so flipping a flag in the console
during manual testing takes effect on the next launch rather than the next day.

`isTestsRunning: true` keeps the defaults and skips the fetch — the layer stays
usable and answers exactly what the app registered, so a UI test asserting on a
remote-driven screen is not at the mercy of the console. This is the one SDK
that a test run does not silence, because its defaults *are* the test's input.

Two states record a line in `configurationIssues` and leave every read
answering the registered default: Firebase not configured before
`IntegrationKit.configure(...)`, and an empty `remoteConfigDefaults` (no fetch
is made — there is nothing to compare a fetched value against).

## Analytics

```swift
public protocol AnalyticsTracking: AnyObject {
	func logEvent(_ event: String, properties: [String: Any]?)
	func setUserProperties(_ properties: [String: Any])
	func setUserId(_ userId: String)
	var deviceId: String? { get }
	func updateTrackingAuthorization(_ status: ATTrackingManager.AuthorizationStatus)
	func flush()   // since 0.9.0
}
```

There is no `configure` on this protocol, by design. The composition root owns
that call and makes it against the concrete layer, which is internal, so the app
can neither reach it nor re-run it. Re-running it is what the removal prevents:
a second call replaces the `Amplitude` instance, and the "add the IDFA plugin
once" flag lives on the layer rather than on the instance — so the *new*
Amplitude never gets the plugin and every event after that point silently loses
the IDFA. `logEvent(_:)` without properties is available through a protocol
extension:

```swift
public extension AnalyticsTracking {
	func logEvent(_ event: String) {
		logEvent(event, properties: nil)
	}
}
```

Usage:

```swift
kit.analytics.logEvent("app_open")
kit.analytics.logEvent("onboarding_step_completed", properties: ["step": 2])
kit.analytics.setUserProperties(["locale": "en_US"])
```

The package accepts event names as plain `String` — it does not define an
event enum. Keeping one (e.g. a `LogEventKey` enum) is the app's decision.

`flush()` (since 0.9.0) asks Amplitude to send what it has queued now instead of at
its next batch. Call it right after an event the app cannot afford to leave behind
a short session — the first open, whose batch otherwise goes out only if the app
lives long enough or is backgrounded cleanly:

```swift
kit.analytics.logEvent("first_open_custom")
kit.analytics.flush()   // queued behind the event above, so that event is in the push
```

It is a request, not a guarantee. Nothing comes back, with no network the events
stay in Amplitude's own queue, and an app suspended or killed before the upload
finishes can still lose the batch — the call shortens that window, it does not
close it. It does nothing while the layer is off (empty key, test run), never
reaches Firebase Analytics (which has no equivalent), and creates no event of its
own. Amplitude already flushes when the app goes to the background; `flush()` is for
the seconds before that. Since the protocol gained a member, anything in your
code that conforms to `AnalyticsTracking` — a test double, say — has to implement
`flush()`: there is no default, so the compiler names the one that forgot.

`setUserProperties` reaches Amplitude and, since 0.8.0, Firebase Analytics — see
[Firebase Analytics](#firebase-analytics). To write the same pair
to the Adapty profile as well, use `kit.setUserProperty(value:key:)` — see
[Where a user property lands](#where-a-user-property-lands). In a debug build
each pair prints on its own line, which is what to search the console for when
a property never showed up in the dashboard:

```
[IntegrationKit][AmplitudeAnalytics] UserProperty: logoCountGenerated | value: 2
```

An empty console right after the call proves nothing: Amplitude batches
identify-only calls on its own interval — 30 seconds is both the default and
the minimum — so the line above is the evidence that the value was handed over,
not the dashboard.

**ATT.** Forward the tracking authorization result through the facade, not
directly to Amplitude — it also reaches Adapty's attribution:

```swift
ATTrackingManager.requestTrackingAuthorization { status in
	kit.updateTrackingAuthorization(status)
}
```

`IntegrationKit.updateTrackingAuthorization(_:)` calls
`analytics.updateTrackingAuthorization(_:)` and Adapty's own ATT status
update, in that order.

Calling it is not what enables the IDFA, and forgetting to call it does not
lose the permission: Amplitude's IDFA plugin is attached at `configure` time
and re-reads `ATTrackingManager.trackingAuthorizationStatus` on **every**
event. An answer that arrived before `configure` is picked up on the next
event, and a permission the user revokes later in Settings stops the IDFA
immediately, with nothing to call. What the forward is still needed for is
Adapty, which cannot read the status itself.

**The current status also goes to Adapty on every launch, by itself.**
`IntegrationKit.configure(...)` reads `ATTrackingManager.trackingAuthorizationStatus`
and hands it to Adapty — the status is state, not install data, and a user who
changes it later in Settings would otherwise stay on the answer they gave at
the first dialog forever. So the app has exactly one job here: forward the
result of the system dialog when it shows. The every-launch resend is not
something to call, or to remember.

**First-open event.** Pass a name through `firstOpenEvent` at `configure`
time and the package logs it **once per install**. The gate is a flag in
`UserDefaults`, so a relaunch never double-logs it — and a **reinstall does**,
because the flag goes away with the app. Once per install is the guarantee,
not once per device: an install funnel counted from this event counts
reinstalls as new installs. Pass `nil` to opt out; a `nil` name deliberately
leaves the gate open, so a build that ships before the event has a name does
not spend it for the whole cohort it touched. The event reaches Firebase like
any other, so do not name it after one of Firebase's own events — `first_open`
is on its reserved list, and an event with that name is not sent there (see
below). Pick a name of your own, such as `app_first_open`.

### Firebase Analytics

Since 0.8.0 the package depends on the full `FirebaseAnalytics` product, and
everything the app sends to Amplitude goes to Firebase in the same call:
`kit.analytics.logEvent`, `setUserProperties` and `setUserId`. The app writes
nothing new and **renames nothing** — Firebase gets the same names, or nothing.
Both halves are independent: an empty `amplitudeKey` switches Amplitude off and
not Firebase, and a Firebase that is not up never stops Amplitude.

**What it needs from the app**

1. `FirebaseIntegration.configure(isDebug:)` before `IntegrationKit.configure(...)`,
   as before. With Firebase not up nothing reaches it, and one line saying so —
   with the call to make — lands in `configurationIssues`. A test run that never
   brings Firebase up gets no such line.
2. **`-ObjC` in Other Linker Flags of the app target.** Firebase's own
   `SwiftPackageManager.md` (12.19.2) says Analytics requires it; a maintainer
   says in firebase-ios-sdk issue #16634 that SPM generally manages without it,
   and the two statements have not been reconciled. 12.19.0 and 12.19.1 crashed
   at launch without the flag (`-[APMMeasurement fetchSBT]`), which is why the
   package's floor is 12.19.2. The package cannot set a linker flag for you, so
   the safe course is to set it and check a build without it only if you must.
3. Nothing in `Info.plist` is required. One key is worth knowing:
   `FIREBASE_ANALYTICS_COLLECTION_ENABLED = NO`. The package switches collection
   on or off at `configure` (below), but Firebase starts collecting its
   automatic events (`first_open`, `session_start`) the moment
   `FirebaseApp.configure()` runs — a window of a few lines between that call and
   the package's own. On a clean device a test run can record an automatic event
   inside that window. The key closes it from the first instant; the package then
   enables collection itself on every normal launch, so nothing is lost. Not
   checked against a live dashboard.

**What the package does by itself**

| What | When | Why |
|---|---|---|
| `Analytics.setAnalyticsCollectionEnabled(!isTestsRunning)` | Every launch | Firebase stores the flag between launches, so a test run that only ever switched it off would leave the device off for every build installed after it. A debug build collects like a release one — without it there is no DebugView — and the `environment` property tells the two apart. |
| Every event, user property and user id | Same call as Amplitude | One hand-over covers the facade, Adapty's and AppsFlyer's own events. An app that still calls `Analytics.logEvent` itself gets no duplicate from the package, and no help either — see the migration note below. |
| `Analytics.logTransaction(_:)` | After a successful purchase, on both paths — Adapty's and the StoreKit fallback | Firebase does not see StoreKit 2 purchases by itself. Only a transaction whose signature verified is sent. A cancel, an Ask to Buy waiting for approval and a failure send nothing. |
| `Analytics.appInstanceID()` into the Adapty profile | At launch and on every return to the foreground, until Firebase has one | So a purchase in Adapty can be found in Firebase. An unchanged id is sent once per process. |

**A test run stays half-silent.** With `isTestsRunning: true` the package sends
Firebase no event, no user id, no property and no purchase, and does not read
the instance id — but it does write `setAnalyticsCollectionEnabled(false)`, for
the reason in the table. The Firebase layer is not part of the "everything off"
set the other SDKs are in: crash collection still follows `isDebug` alone.

**What Firebase would drop is not sent, and says so.** Firebase answers an
invalid name or an oversized value by dropping it and logging an `error` event
into your own dashboard, so the package checks first, and a refusal is an
`error` line in the DEBUG log naming the name and the reason. Amplitude is never
affected — it gets the original.

| Case | What the package does |
|---|---|
| Event name not `A-Za-z0-9_`, over 40 characters, not starting with a letter, with a `firebase_`, `google_` or `ga_` prefix, or one of Firebase's reserved names (`first_open`, `session_start`, `error`, `app_update`, and 26 more) | The event is not sent to Firebase. Amplitude gets it as usual. |
| Parameter key invalid by the same rules (40 characters) | That parameter is not sent; the rest of the event is. |
| String parameter over 100 characters (UTF-16 units, without splitting a character) | Cut to 100, and the line says from what to what. Firebase would drop the whole parameter instead. |
| More than 25 parameters | All are sent and an `error` line gives the count — which ones Firebase drops is not documented, and the package does not choose for it. |
| Value that is not String, Int or Double | `Bool` becomes `"true"`/`"false"`, anything else is `String(describing:)`; `NSNull` has no form there and is left out. |
| User property name over 24 characters, invalid, with a reserved prefix, or `user_id` / `first_open_time` / `last_deep_link_referrer` | Not sent. |
| User property value over 36 characters | Cut to 36. `NSNull` removes the property in Firebase. |
| User id empty or over 256 characters | Not sent — an empty one would join every profile to nobody, a cut one would join different users into one. |

Firebase takes 25 user property names in all. The package writes five of its
own — `environment`, `status`, `media_source`, `campaign_name`, `deep_link_value`
— and cannot count the app's, so the 25 are shared: leave room.

**Migrating an app that calls `Analytics.logEvent` itself.** Replace the calls
with `kit.analytics.logEvent(...)`: one call then reaches both SDKs, in the
same order, with the sanitising above. Leave the old calls in and every such
event is only in Firebase, with none of the checks — and, if the same event is
also sent through the kit, twice.

**Purchases: two revenue events, and why.** The package logs `in_app_purchase`
(Firebase's own name for a StoreKit 2 purchase). Adapty's server-side Firebase
integration, if you switch it on, sends `purchase` — a different name — and
Google Analytics adds up both, so revenue on a first purchase is counted twice.
That integration is not set up in the current apps; if you enable it, remap its
events in the Adapty dashboard so only one of the two names carries revenue.
Two limits of `in_app_purchase` itself: a purchase that reaches the app another
way — an Ask to Buy approved later, an interrupted purchase Adapty picks up on
the next launch, a restore — is not logged, because the package deliberately
keeps no transaction listener of its own; and renewals are Firebase's own
business. Two things are **not verified without a live DebugView**: that Firebase
accepts a transaction Adapty has already finished (on the Adapty path it is
finished before the package sees it), and what it sends for a free trial.

## Crash reporting

```swift
public protocol CrashReporting {
	func recordNonFatal(_ tag: String, _ error: Error, _ info: [String: Any])
	var droppedReports: Int { get }
}
```

A protocol extension drops the `info` dictionary when there is nothing extra
to attach:

```swift
public extension CrashReporting {
	func recordNonFatal(_ tag: String, _ error: Error) {
		recordNonFatal(tag, error, [:])
	}
}
```

```swift
kit.crashes.recordNonFatal("network", someError)
kit.crashes.recordNonFatal("purchase", someError, ["placement": "main"])
```

That is the entire surface — `recordNonFatal` is the only method
`CrashReporting` exposes. There is no `log(_:)` and no way to set a user id
on the crash reporter through this protocol (Crashlytics's own `setUserID`/
custom-log APIs are not exposed here); if your app needs breadcrumb logging
or a Crashlytics user id, that has to go through Firebase directly, outside
this package, since `IntegrationKit` does not expose a hook for it today.

Internally, `recordNonFatal` filters out network noise before it reaches
Crashlytics (`NSURLErrorNotConnectedToInternet`, `NSURLErrorCancelled`) — no
action needed from the app for that.

### The `tag` is filterable, the `info` is not

`tag` is written as the Crashlytics **custom key** `ik_tag` before the report
is filed, so the dashboard can filter and group on it. The `info` dictionary
goes in as the report's `userInfo`, which Crashlytics shows only *inside* an
issue that is already open — useful for reading one report, useless for
finding it. Put in `tag` what you would search for; put in `info` what you
would want once you are looking at the report.

### Order matters, and the count says when it was wrong

`FirebaseIntegration.configure(isDebug:)` must run **before**
`IntegrationKit.configure(...)`. A report filed while Firebase is not up
cannot be delivered, so it is dropped, counted, and the reason is recorded
once in `kit.configurationIssues`:

```swift
if kit.crashes.droppedReports > 0 {
	// FirebaseIntegration.configure(isDebug:) ran too late — or not at all.
}
```

`droppedReports` counts every dropped report; the issue line is written once.
Both are readable in a release build, which is the point — nothing here
depends on a DEBUG log.

### What switches collection on and off

```swift
FirebaseIntegration.configure(isDebug: isDebug)
```

Collection is on exactly when `isDebug` is `false`. There is no second switch:
the app's own `#if DEBUG` is the whole policy, so a developer's crashes stay
out of the dashboard and a shipped build's go in.

`isTestsRunning` deliberately does not reach this call. It silences Amplitude,
Adapty and AppsFlyer; Firebase stays up, because a test run that was meant to
catch crashes must not be the run that loses them.

**The flag is written on every launch, in both directions, and that is not
symmetry for its own sake.** Crashlytics persists it in `NSUserDefaults` under
`com.crashlytics.data_collection` and reads it while starting up, so it
survives the build that wrote it. A package that only knew how to switch
collection *off* would leave every device that ever ran a debug build dark for
every build installed on it afterwards — including the release one. So the
value is set explicitly each launch rather than left to a default.

Two consequences worth knowing before debugging a silent dashboard:

- **The change applies from the *next* launch**, not from this one. The
  current session keeps whatever the previous launch set. That is the SDK's
  rule, not this package's.
- A device that last ran a debug build has collection off *right now*. The
  first release launch after it turns the flag back on, and reports start
  arriving from the launch after that.

Calling `FirebaseIntegration.configure(isDebug:)` a second time in one process
does nothing: a second `FirebaseApp.configure()` raises an `NSException` that
no Swift `catch` can stop, so the call returns early when Firebase is already
up.

### Checking a live crash on a real device

Crash *reporting* cannot be verified from Xcode — with a debugger attached the
SDK installs no signal or mach-exception handlers at all, so the crash is
caught by the debugger and nothing is ever written. The procedure:

1. Build **Debug**, but pass `isDebug: false` to
   `FirebaseIntegration.configure(...)` for this build only. That is what the
   key exists for: no Release build, no archive, no `#if` inside the package to
   fight.
2. Install the app and launch it **from the home screen**, not from Xcode. Let
   it reach the first screen — this launch is the one that turns collection on.
3. Force a crash (`fatalError()` behind a debug button, or Crashlytics's own
   test crash).
4. **Launch the app again.** The report is written on the crash and uploaded on
   the *next* start; it never appears while the app is still down.
5. Set `isDebug` back to the app's own `#if DEBUG` afterwards, or every
   developer's crash lands in the production dashboard from then on.

## Premium

`PremiumServicing` is the single entry point for paywalls, products,
purchases and the current premium flag. Adapty and the Apple receipt are
both internal to the implementation behind it.

```swift
public protocol PremiumServicing: AnyObject {
	var isPremium: Bool { get }
	func hasAccess(level: String) -> Bool   // since 0.11.0, defaults to isPremium
	func start()
	func refresh()
	func restore(completion: @escaping (RestoreOutcome) -> Void)
	func purchase(_ productId: String, placement: String, completion: @escaping (PurchaseOutcome) -> Void)
	func activeSubscriptionIds(completion: @escaping (Set<String>?) -> Void)   // since 0.10.0
	func product(_ productId: String, placement: String, completion: @escaping (PremiumProduct?) -> Void)
	func products(placement: String, completion: @escaping ([PremiumProduct]) -> Void)
	func hasPaywall(placement: String) -> Bool
	func paywallState(placement: String) -> PaywallState
	func remoteValue<T>(placement: String, key: String) -> RemoteValue<T>
	func logPaywallOpen(placement: String)
	var configurationIssues: [String] { get }
}
```

`start()` is already called once by `IntegrationKit.configure(...)` — the app
never calls it. `isPremium` is synchronous and reads from cache, no network
round trip; the source of truth behind it is Adapty first, the App Store
receipt as a fallback when Adapty has not answered yet.

### What decides `isPremium`, and what can take it away

Three candidates go in — Adapty's answer, the App Store receipt, the state
cached from the last launch — and one verdict comes out. The order of the
branches *is* the rule, and it is not simply "Adapty, then the receipt".
Adapty hands premium out and never takes it back (user's decision,
2026-09-11, commit `340d901`); what closes access is the expiry date and
Apple's receipt:

1. **Adapty says active** → premium, and the local-purchase mark is dropped.
   An answer that has not been confirmed over the network yet still grants:
   doubt goes to the user.
2. **The cache**, when it is verified or premium and has not expired → it
   stands as it is, and the receipt is never consulted. Its expiry date mirrors
   the Adapty profile: it is refreshed from Adapty's answer on every pass,
   including a denial.
3. **The receipt**, and only once the cache is gone or expired: active and not
   past its expiry date grants premium and carries the date with it; anything
   else leaves premium off. A purchase or restore that just went through on
   this device counts as a receipt saying "yes" — newer than any cached
   verdict, which stops being verified against it.
4. **Nobody answered** → not premium.

Adapty's `isActive == false` is not an answer at all: it falls through exactly
like silence, whether it was checked over the network or not, with a local
purchase outstanding or not. So no branch can tell a denial from silence, and
Adapty can only grant. The two things that can actually close premium are an
**expiry date that has passed** and **Apple's receipt** once the cache no
longer holds. A premium the store knows nothing about is one the dashboard
handed out, and Adapty writes an end date on those — so the date takes it
back. A `false` from the receipt revokes nothing on its own: with a live
premium cache the verdict never reaches branch 3. The local-purchase mark is
still computed, carried and stored (seven days), but under this rule it
decides nothing today. One question stays open: a grant that arrives with no
date can never be revoked. The asymmetry is deliberate: a short free ride for
someone who did not pay costs less than a paywall shown to someone who did.
The code is `Sources/IntegrationKit/Premium/Helpers/PremiumResolver.swift`.

### The paywall-to-purchase flow

```swift
func paywall() {
	kit.premium.logPaywallOpen(placement: "main")

	// Four different reasons for "no title", not one nil.
	let title: RemoteValue<String> = kit.premium.remoteValue(placement: "main", key: "title")
	switch kit.premium.paywallState(placement: "main") {
		case .ready: break          // draw the paywall
		case .loading: break        // spinner — ask again in a moment
		case .unavailable: break    // nothing is coming; fall back to a hardcoded screen
	}

	kit.premium.products(placement: "main") { products in
		for product in products {
			print(product.localizedTitle, product.localizedPrice ?? "—")
		}
	}

	kit.premium.product("year.sub", placement: "main") { product in
		guard let product else { return }
		kit.premium.purchase(product.id, placement: "main") { outcome in
			switch outcome {
				case .purchased:
					// kit.premium.isPremium is already true by this point.
					break
				case .cancelled:
					break
				case .pending:
					// Ask to Buy waiting for a parent, or a purchase that never came back. Show
					// waiting, never an error, and do not offer to buy again — the answer arrives
					// through .premiumDidChange.
					break
				case .unavailable:
					// Permanent for this device/product. Hide the button instead of retrying.
					break
				case .failed:
					break
			}
		}
	}
}
```

- **`logPaywallOpen(placement:)`** — logs the paywall-shown event to Adapty.
  Call it when the paywall screen appears, not before.
- **`hasPaywall(placement:)`** — whether Adapty has a paywall configured for
  this placement at all. `false` for a placement that was never preloaded
  (see `placements` at `configure` time) or does not exist in the Adapty
  dashboard.
- **`paywallState(placement:)`** — *why* there is no paywall, which one
  boolean cannot say: `.ready`, `.loading` (an attempt is in flight or
  scheduled — draw a spinner and ask again) or `.unavailable` (the placement
  was never configured, or Adapty answered that it does not exist — retrying
  will not change it). Use this to choose between a spinner and an empty
  state; keep `hasPaywall` for the plain yes/no.
- **`remoteValue<T>(placement:key:)`** — reads a value out of the paywall's
  remote config by key. Answers a `RemoteValue<T>`, not a bare optional,
  because four different situations used to collapse into one `nil`:
  `.value(T)`, `.notReady` (the paywall has not arrived — ask again),
  `.noConfig` (the paywall carries no remote config at all), `.notSet` (the
  config has no such key) and `.wrongType` (the dashboard set it to another
  type — that one also lands in `configurationIssues`). `.value` gives the
  plain optional back when the distinction does not matter, and `.isPending`
  is the "ask again later" test.
  **Since 0.3.0 Adapty hangs one remote config per locale off a placement**, and
  its `getFlow` takes no locale to narrow them with, so the package chooses:
  the device's locale exactly, then its language (an `en-GB` device is served by
  an `en` config), then the dashboard's first row — and that last one records a
  line in `configurationIssues` naming the placement and the locale that was
  missing. A paywall quietly rendering in the wrong language is a bug nobody
  reports and everybody sees. The call site is unchanged.
- **`configurationIssues`** — every cause the package could not work around
  and no retry will fix: an empty key, a device id that arrived too late, a
  placement that does not exist, a product the paywall does not sell, a
  profile attribute Adapty refused. One line per cause, oldest first. Empty
  is the healthy state; print it in DEBUG, ship it to Crashlytics as a
  non-fatal, or assert on it in an integration test.
- **`products(placement:completion:)`** / **`product(_:placement:completion:)`**
  — `PremiumProduct` values for a placement, or a single one by product id.
  Two sources, one list: **Adapty decides which products the placement carries**
  (it owns the paywall), **StoreKit decides what they cost** (it owns the
  storefront), so the price, currency, period and introductory offer come from
  the store whenever it answers. A product the store stays silent about — not
  approved yet, wrong bundle id, offline — keeps Adapty's own price rather than
  disappearing from the paywall. Both complete with an empty result / `nil` if
  the placement has no paywall or no matching product.
- **`purchase(_:placement:completion:)`** — takes a `PremiumProduct.id`. When
  Adapty's own purchase request fails and asks for a StoreKit retry, the
  package runs that retry itself through its own StoreKit layer — the app never
  sees a "please retry" signal, only the final `PurchaseOutcome`.
- **`restore(completion:)`** — runs StoreKit's restore, then re-asks both
  sources, then calls you back. The `RestoreOutcome` is **StoreKit's own
  answer, not a combined verdict**: Adapty is re-asked only so that `isPremium`
  is already current by the time the completion fires. They are two separate
  readings — the outcome says what the payment queue gave back, `isPremium`
  says whether the user has access.
  **`.nothingToRestore` together with `isPremium == true` is a normal pairing,
  not a contradiction**, and it is the one an integrator meets in the wild: a
  subscription bought on another Apple ID, a purchase made on the web, or a
  grant handed out in the Adapty dashboard leaves StoreKit with nothing to
  hand back while Adapty answers "active". Read `isPremium` first and say
  "your subscription is already active"; keep "no active purchases found" for
  `.nothingToRestore` with `isPremium == false`. Telling a paying user that
  nothing was found is how a support ticket or a refund request starts.
- **`refresh()`** — re-asks both sources and updates the cached state. **There
  is no de-duplication**: every call starts a pass of its own, and two
  overlapping calls run two of them. That is a deliberate limit of the
  contract, not a defect — the store write and the `.premiumDidChange`
  notification stay one per actual change, so the extra passes cost network
  rather than correctness. The network is the part that matters: each pass
  validates the receipt against Apple's production endpoint, so a `refresh()`
  wired to every `viewWillAppear` is a storm Apple throttles. A throttled
  receipt answers "could not be checked", which removes the offline reserve at
  exactly the moment it was there for. Call it where the state can really have
  changed behind the app's back — returning to the foreground, opening the
  paywall or the settings screen, coming back from a subscription managed in
  Settings. Most apps need it nowhere else: `configure` runs the first pass,
  `purchase` and `restore` re-ask on their own, and Adapty pushes profile
  updates in by itself.

### Models

```swift
public struct PremiumProduct: Equatable, Sendable {
	public let id: String
	public let localizedTitle: String
	/// `nil` when the store gave no formatted price. Deliberately not `""` — an empty string
	/// renders as a blank button and cannot be told from a real price.
	public let localizedPrice: String?
	public let price: Decimal
	public let currencyCode: String?
	public let subscriptionPeriod: PremiumPeriod?
	public let introductoryOffer: PremiumOffer?
}

public struct PremiumPeriod: Equatable, Sendable {
	public enum Unit: String, Equatable, Sendable { case day, week, month, year, unknown }
	public let unit: Unit
	public let numberOfUnits: Int
}

public struct PremiumOffer: Equatable, Sendable {
	public enum PaymentMode: String, Equatable, Sendable { case payAsYouGo, payUpFront, freeTrial, unknown }
	public let price: Decimal
	public let localizedPrice: String?
	public let period: PremiumPeriod
	public let numberOfPeriods: Int
	public let paymentMode: PaymentMode
}

public enum PurchaseOutcome: Equatable, Sendable {
	case purchased
	/// The user said no.
	case cancelled
	/// Neither bought nor refused **yet**: Ask to Buy waiting for a parent, or a purchase call that
	/// never came back. Show waiting, not an error, and do not offer to buy again.
	case pending
	/// Not possible on this device or for this product: payments disabled, product missing from the
	/// storefront, a promotional offer the store refuses to sign. Hide the button.
	case unavailable
	/// Everything else that is neither a purchase nor a user cancel.
	case failed
}

public enum RestoreOutcome: Equatable, Sendable {
	case restored
	case nothingToRestore
	case failed
}
```

`PurchaseOutcome.failed` and `RestoreOutcome.failed` both cover the StoreKit
fallback path too — the "retry through StoreKit" signal from Adapty never
leaves the package, it always resolves to one of these five/three cases
before reaching the app.

Three of the five need a UI decision that `failed` would get wrong:

| Outcome | What the screen should do |
|---|---|
| `.pending` | "Waiting for approval" — no error, no second buy button. The real answer arrives through `.premiumDidChange`. Treating it as a failure is how a user with a pending Ask to Buy request creates a second one. |
| `.unavailable` | Hide or disable the button. A retry fails identically every time. |
| `.failed` | Show an error and let the user try again — this one really is temporary. **It is also what a second tap on the buy button gets while the first purchase is still in flight.** The package refuses the second call before the SDK ever sees it, so two payment sheets can never stack; the app is not expected to disable the button itself. Do not turn that into an alert — a purchase is already running, so the screen should be waiting, and the outcome of the first call is the one to react to. |

### Active subscriptions

Since 0.10.0.

```swift
kit.premium.activeSubscriptionIds { ids in
	guard let ids else { return }   // unknown — Adapty did not answer; decide without it
	let hasWeeklyOnly = ids.contains("week.sub") && !ids.contains("year.sub")
}
```

`isPremium` says there is access; this says *through which subscription* — for
the screen that has to choose a cohort, because a weekly user and a yearly one
are not offered the same upsell.

- **Adapty only.** The receipt, the cached verdict and the local-purchase mark
  take no part: the question is not "is there access" but "which subscriptions
  does Adapty see as active".
- **Three kinds of answer.** A set of product ids; `[]`, which means Adapty
  answered and nothing is active; and `nil`, which means Adapty did not answer
  — the layer is off (empty or invalid key, a test run without test mode), or
  no profile came before the deadline. `nil` is "unknown", never "none": a
  screen that reads it as "no subscription" will show an upsell to a user who
  already pays. An inactive layer answers `nil` at once and does not spend the
  deadline.
- **Exactly what Adapty marks active.** The ids are the store product ids of
  every subscription whose `isActive` is true. A subscription in its grace
  period is active, a refunded or expired one is not, and the package adds no
  rule of its own — in particular it does not compare the expiry date, which in
  a grace period is already in the past. The set is **not** filtered by the
  `productIds` given to `configure`: a subscription the app no longer sells
  comes back too, and what to do with it is the app's decision.
- **Offline is still an answer.** Without a network Adapty hands over the
  profile it saved last, and the set is taken from that as it is. It can be
  stale — a weekly subscription that ended since is still in it — and that is
  accepted.
- **The screen deadline.** The same short one `purchase` and `restore` use
  (`waitingTimeout`, 2 seconds by default), not the longer one a background
  refresh gets: the caller is a screen with a person in front of it.
- **Read-only.** It writes nothing, posts no `.premiumDidChange` and leaves the
  verdict and the cache as they were, even when the profile disagrees with
  `isPremium` (a promo, a local purchase). It never changes who is premium.
- **The callback** runs exactly once, on the main queue, and never inside the
  call itself — also when the answer is known at once. Two calls at once are two
  requests; there is no de-duplication, the same limit `refresh()` has.
- **In the DEBUG log**, tag `PremiumService`: how many ids came back, and an
  `error` line for a timeout or an inactive layer.

**In a test run**, `-activeSubscription <productId>` tells the fake Adapty which
subscriptions are active. It is the one repeatable flag: every occurrence adds
an id, and the same id twice is one.

| Flags | `activeSubscriptionIds` |
|---|---|
| `-premium -activeSubscription year_50` | `["year_50"]` |
| `-premium -activeSubscription week_9_trial_3d -activeSubscription year_50` | both |
| `-premium` alone | `[]` — premium without a subscription (a promo, a manual grant) |
| `-noPremium`, or no flag at all | `[]` — subscriptions travel with the grant only |
| `-adaptySilent` | `nil` |

The profile is a real `AdaptyProfile`, decoded from the keys the server sends,
so what a test sees is what `activeSubscriptionIds` reads in production. A
deferred `-premiumAfter` brings the same ids with it; `-noPremiumAfter` brings
none. The ids never change the verdict (`isPremium` is still decided by the
access level alone) and never change the price list. A flag with no value after
it, or followed by another flag, is ignored and recorded in
`configurationIssues`.

### Access per level

Since 0.11.0. For an app with more than one access level in the Adapty
dashboard — say `lifetime` (a one-time purchase) and `remote_play` (a
subscription) — where buying one must not open the other.

```swift
let kit = IntegrationKit.configure(
	// …
	productIds: ["cg.lifetime", "rp.month", "rp.year"],
	levels: ["lifetime", "remote_play"],
	productLevels: ["cg.lifetime": "lifetime", "rp.month": "remote_play", "rp.year": "remote_play"]
)

if kit.premium.hasAccess(level: "remote_play") { startRemoteGame() }
```

- **Each level is its own verdict**, through the same arbiter as `isPremium`:
  Adapty only opens (that level and its own expiry date), the receipt counts
  only the products the map ties to that level, a cached open level holds
  offline, and doubt goes to the user.
- **A purchase opens one level** — the one the map ties the bought product to,
  whether Adapty sold it or the StoreKit fallback did. Inside the purchase
  completion `hasAccess` is already up to date. A product with no level in the
  map opens none. A restore opens the levels whose products Apple handed back;
  a transaction delivered by the payment queue carries no product, so the
  receipt and Adapty decide.
- **A level with no product in the map** (a promo, a manual grant from the
  dashboard) is opened by Adapty alone.
- **A map that disagrees with the dashboard** (the map ties a product to one
  level, Adapty unlocks another with it) closes nothing: Adapty opens its level,
  the receipt opens the map's. A DEBUG line names both — check the map against
  the dashboard. Every update also logs each level with the source that decided it.
- **`.premiumDidChange`** is the same notification, posted once when
  `isPremium` or any level changed; re-read the levels you need. Nothing
  changed, nothing posted.
- **`isPremium` is untouched**: still "any access at all", computed exactly as
  before. With a map, decide what to unlock by `hasAccess` only.
- **The first launch with a map** starts every level closed: the old verdict is
  not copied into a level, because nobody knows which level it meant. The first
  receipt answer (it works offline) or Adapty answer brings access back.
- **Without a map** `hasAccess(level:)` answers `isPremium` for every level in
  `levels`. Nothing per level is computed, stored or posted.
- **A level not in `levels`** answers `false` and leaves one line in
  `configurationIssues` — usually a typo.

**In a test run**, `-grantLevel <levelId>` adds a level to what the fake Adapty
grants. It is repeatable and adds up with `-adaptyLevelId`; without either, the
grant carries the app's first level, as before. A denial carries none.

| Flags (map as above) | `lifetime` | `remote_play` | `isPremium` |
|---|---|---|---|
| `-premium -grantLevel lifetime` | open | closed | `true` |
| `-premium -grantLevel remote_play` | closed | open | `true` |
| `-premium -grantLevel lifetime -grantLevel remote_play` | open | open | `true` |
| `-premium` alone | open (first level) | closed | `true` |
| `-noPremium`, `-adaptySilent`, or no flag | closed | closed | `false` |

A deferred `-premiumAfter` brings the same levels; `-noPremiumAfter` brings
none. `-noPremiumCache` wipes the per-level verdicts with the general one. The
fake receipt does not narrow by level: `-receiptValid` opens every level.

### Promoted purchases

An App Store product page can promote an in-app purchase, and tapping it opens
the app with a purchase already half-started. **The package refuses it** and
writes a log line saying which product was refused.

That is a deliberate choice, and it is a choice because Adapty's delegate
protocol makes it one: `AdaptyDelegate` ships a default implementation of
`didReceivePromotedPurchase` that calls `Adapty.makePurchase` straight away. So
conforming to the protocol and staying silent is not neutral — it signs the app
up to buy whatever the store page promoted, outside `PremiumService`'s
single-purchase guard, with no paywall shown, no impression logged, and no
`PurchaseOutcome` delivered to anybody. The package has no way to ask the app
whether it wants that, so it declines.

An app that wants to sell a promoted product does it the ordinary way: catch
the deep link into the paywall and offer the product through
`purchase(_:placement:)`, where the guard, the impression and the outcome all
apply.

### Reacting to premium changes

```swift
NotificationCenter.default.addObserver(
	forName: .premiumDidChange,
	object: nil,
	queue: .main
) { _ in
	print("premium is now \(kit.premium.isPremium)")
}
```

`Notification.Name.premiumDidChange` fires only when the flag actually
changes value — never on a write of the same value — always on the main
queue.

## The StoreKit side

There is nothing to implement. StoreKit lives inside the package
(`Sources/IntegrationKit/StoreKit/`), on native StoreKit 2 since 0.7.0, and
the app's whole contribution is one `configure` argument: `productIds`.
`AppleSubscribing`, which earlier releases asked the app to implement, is
internal now.

What the package does with them:

- **Receipt validation** — `Transaction.currentEntitlements`, filtered to
  `productIds`. This reads the device's own transaction cache: it does not
  throw and it works offline, so `nil` from `checkReceipt()` means a genuine
  surprise (Apple removing the sequence's guarantees), never "offline" or
  "sandbox" the way a network receipt validator could answer. There is no
  shared secret to configure and no server round trip to make — validation is
  local and cryptographic, on Apple's own side.
- **Restore** — `AppStore.sync()`, StoreKit 2's replacement for
  `SKReceiptRefreshRequest`. Anything found among current entitlements
  afterwards is `.restored`.
- **The fallback purchase** — `product.purchase()`, run by
  `PremiumServicing.purchase(_:placement:completion:)` itself when Adapty's own
  request asks for a StoreKit retry. The app never sees the retry, only the
  final `PurchaseOutcome`. An unverified transaction — StoreKit's own signature
  check failing on a transaction just paid for — resolves to `.failed`, the
  same stance Adapty takes for a transaction its own listener cannot verify:
  not granted.
- **Interrupted transactions** — the kit runs no transaction-queue-parsing loop
  of its own and never calls `Transaction.finish()` anywhere. Adapty (full
  mode) is the only finisher: its own live `Transaction.updates` listener
  finishes what it sees and calls `AdaptyDelegate.onUnfinishedTransaction`,
  which the composition root wires straight to re-asking the premium barrier;
  its sweep of `Transaction.unfinished` (triggered by a profile sync, restore
  or activation) finishes the rest without a delegate callback. A second
  finisher racing Adapty's is exactly the crash this design avoids.
- **Prices** — `Product.products(for:)` for the ids Adapty listed on the
  placement; see the note under `products(placement:)` above. A missing key
  means the store said nothing about that id (not approved yet, wrong bundle,
  offline) — never a fabricated zero price.

## Deep links

```swift
public func handleContinue(_ userActivity: NSUserActivity, restorationHandler: @escaping ([UIUserActivityRestoring]?) -> Void)
public func handleOpen(_ url: URL, options: [UIApplication.OpenURLOptionsKey: Any])
```

Forward both `AppDelegate` callbacks through `kit`, not to AppsFlyer
directly — AppsFlyer's own service type is internal, this is the only way to
reach it:

```swift
func application(_ application: UIApplication, continue userActivity: NSUserActivity, restorationHandler: @escaping ([UIUserActivityRestoring]?) -> Void) -> Bool {
	kit?.handleContinue(userActivity, restorationHandler: restorationHandler)
	return true
}

func application(_ app: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
	kit?.handleOpen(url, options: options)
	return true
}
```

- **Universal Links** (`handleContinue`) need the Associated Domains
  capability with `applinks:<AppsFlyer OneLink domain>`. Without it, iOS
  never calls `application(_:continue:restorationHandler:)` in the first
  place — this is a project setting, not something the package can detect
  or fall back around.
- **URL scheme** (`handleOpen`) needs `CFBundleURLTypes` in `Info.plist`,
  independent of the package.
- If `appsFlyerDevKey` was empty at `configure` time there is no AppsFlyer
  instance behind either method, but they are not both no-ops, and the
  difference matters. `handleOpen` is one: the URL goes nowhere. `handleContinue`
  is not — it still calls `restorationHandler(nil)`, exactly once. That handler
  belongs to UIKit, and an app that leaves it uncalled sits on its launch screen
  for the whole universal-link open. So forward both unconditionally and never
  answer `restorationHandler` yourself as a fallback: calling it twice is a
  UIKit contract violation, and `Checks/Cases/IntegrationKitCheck.swift` pins the
  "exactly once" from the package's side.

**What the package does with a resolved deep link:** logs an
`af_didResolveDeepLink` analytics event, sets a `deep_link_value` user
property, and writes the same value into the Adapty profile. It does not
navigate anywhere. If the app needs to open a specific screen based on the
resolved deep link value, that routing is entirely the app's own code —
`IntegrationKit` has no callback for "the deep link resolved to X".

**When the SDK contradicts itself:** AppsFlyer sometimes answers "deep link
found" and hands over nothing. There is nothing to route and nothing to log,
so the package drops it and counts it — `kit.droppedDeepLinks`, readable in
release like `kit.crashes.droppedReports`. It is not a `configurationIssues`
entry: nothing is misconfigured, so a list meant for causes no retry will fix
would fill up with weather. Anything above zero is paid traffic arriving
nowhere, and only the app can see it in a shipping build.

```swift
if kit.droppedDeepLinks > 0 {
    kit.analytics.logEvent("deep_links_dropped", properties: ["count": kit.droppedDeepLinks])
}
```

## Building and checks

The package does not build standalone — `swift build` targets the macOS host
and fails on iOS-only dependencies, and running `xcodebuild` directly is
blocked by the local build hook. Verification goes through `BuildHost/`, a
minimal iOS app on xcodegen that links the package:

```bash
cd BuildHost && xcb app-sim
```

Changed `BuildHost/project.yml`? Run `xcodegen generate` first.

`Checks/` are self-checks that compile the real source files directly with
`swiftc`, against stub SDK modules in `Checks/Stubs/` — no XCTest, no Xcode
project, no network, no real SDK ever linked. Each script exits non-zero and
prints every failing assert, not just the first. `buildhost-check.sh` is the
one exception and the last row of the table: it is the only script that builds
against the real SDKs, and the only one that needs Xcode.

Every assert is written from a row of an approved risk table and names the
exact value that row names — a verdict, a journal entry, a trace line. `count
== 0` and "something exists" close no row.

```bash
for s in Checks/*.sh; do "./$s"; done
```

| Script | What it pins down |
|---|---|
| `adapty-service-check.sh` | The whole of AD-01…AD-07: activation guards, paywall de-duplication and TTL, the `PaywallState` answers, purchase verdict mapping (including that a server or network error grants nothing), the attribution pair failing by halves, the ATT resend, remote-config parsing done once, locale selection, and the promoted purchase that must not be started. Since 0.8.0 also the purchase half of FA-04: a verified `.success` reaches Firebase once, an unverified one, a cancel, a pending purchase and a failure never do, and a second answer to the same purchase does not log a second payment. |
| `firebase-analytics-check.sh` | FA-01…FA-05 and their boundary with Amplitude (0.8.0): the collection flag written in both directions, "Firebase is not up" recorded once, what the sanitiser refuses and cuts (event names, reserved names and prefixes, parameter keys, the 25-parameter and 100/36-character limits in UTF-16 units, value types, user id), the mirror in the same call as Amplitude, and the Firebase instance id delivered once. |
| `premium-resolver-check.sh` | Arbitration order: a verified Adapty answer beats the cache both ways; a false receipt does not revoke an unverified local purchase; a stale cache plus a true receipt yields unverified state with no `expiresAt`; silence yields `.free`. |
| `premium-barrier-check.sh` | The `refresh()` concurrency barrier, restore, the StoreKit-fallback path, and the price merge — the store's price winning where it answered, Adapty's kept where it did not. Since 0.10.0 also PM-09, `activeSubscriptionIds`: `nil` at once from an inactive layer and at the screen deadline from a hung one, exactly one callback even when the answer and the deadline are due together, `[]` for a profile without subscriptions, exactly the `isActive` ones (grace period in, refunded and expired out, no `productIds` filter), nothing written, notified or renumbered in the arbiter, always on main and never inside the call, and the DEBUG trace. |
| `premium-levels-check.sh` | Since 0.11.0, PM-10 and TM-10 — access per level: a level opened by Adapty, the receipt, a purchase (Adapty and the StoreKit fallback) or a restore never opening another, each level's own date, the map mistakes and an unknown level each one line in `configurationIssues`, no map meaning exactly 0.10.0 (no new key, no per-product receipt question), the offline restart, the first launch with a map starting closed, a corrupted payload, exactly one `.premiumDidChange` per update, the push/refresh race, a queued transaction marking no level, a dashboard-only level, an old app fake compiling against the default, the map/dashboard mismatch line and the per-level trace — and the `-grantLevel` flag: accumulating, adding up with `-adaptyLevelId`, the deferred pushes, the result table through the real arbiter, `-noPremiumCache` and the TM-08 wipe taking the level verdicts too. |
| `premium-local-purchase-check.sh` | The local-purchase mark: what sets it, what may clear it, and what must never clear it. |
| `premium-pending-check.sh` | That one hung purchase does not refuse every later purchase in the process. |
| `premium-storekit-check.sh` | Restore, price lookup, unfinished transactions delivered by the payment queue, and that every SwiftyStoreKit entry point is reached on the main thread even when the caller is not. |
| `crashlytics-check.sh` | Double `configure`, the network-noise filter, and the tags a non-fatal carries. |
| `amplitude-analytics-check.sh` | First-open gating, the IDFA plugin attached exactly once, the environment property, the test-run guard, and the debug log lines for user id, device id and each user property. Since 0.9.0 also AN-05: `flush()` reaches the SDK after the event it follows, once per call even from two queues, nothing at all while the layer is off, never Firebase, and leaves a log line saying whether it went anywhere. Firebase is brought up for the whole run so the mirror stays out of the way — what it does is `firebase-analytics-check.sh`'s business. |
| `appsflyer-service-check.sh` | Session start, attribution mapping, the ATT wait limit, deep-link values. |
| `appsflyer-attribution-check.sh` | `cleanedAttributionData`: `NSNull`/non-scalar values and non-string keys dropped, an empty input staying empty, a `nil` deep link value becoming `"-"`, `clickEvent` fields flowing through. |
| `integration-kit-check.sh` | The composition root, actually run — in two processes of one binary, a normal launch and a test run (`--tests-running`): the `AppDelegate` forwards answering with no AppsFlyer layer, the empty dev key leaving a readable reason, a second `configure` handing back the first kit instead of building a second graph, and (0.8.0) Firebase hearing the collection flag, the user id, the `environment` property and the kit's own Adapty-bound instance id on a normal launch, and only `collection off` in a test run. Since 0.9.1 also TM-08 through the root: a test run marks the device, and a normal launch that finds the mark wipes the premium verdict, legacy flag and prices before `start()` and says so in `configurationIssues`. The other scripts compile a chosen slice of `Sources/` and never compile `IntegrationKit.swift` at all, so a forward that drops a request on the floor is invisible to every one of them. |
| `test-mode-check.sh` | TM-01…TM-09: the test mode — the fake Adapty and Apple sources, and the production arbiter that stays above them. Since 0.9.0 also that `flush()` on the test layer writes nothing to the sink. Since 0.9.1 also TM-08: a test run's fake purchase leaking into the next live launch, and the wipe that stops it — only with the mark, only the package's three keys, without a notification, with one line in `configurationIssues`. Since 0.10.0 also TM-09: `-activeSubscription` accumulating, a missing value dropped without eating the next flag, the fake profile decoding with every key the SDK requires, subscriptions riding on the grant and the deferred grant only, and never touching the verdict or the price list. |
| `remote-config-service-check.sh` | RC-01…RC-03: Remote Config defaults, the fetch, the "is Firebase up" guard, and a failed fetch filed as a non-fatal. |
| `price-cache-check.sh` | PM-07 rows 14–16: the price cache over `UserDefaults`, pure types with no SDK stub. |
| `store-price-check.sh` | PM-07 row 17: `StorePrice`, pure `Decimal` and `Foundation`. |
| `buildhost-check.sh` | That the package still compiles the way an app compiles it — against the real SDKs rather than the stubs in `Checks/Stubs/`, with the real Package.swift resolution behind it. The other seventeen never link a real SDK, so a dependency whose API moved under a `from:` range breaks here first. Runs `xcb app-sim --path BuildHost`, regenerating the xcodegen project first, because the generated `.xcodeproj` is gitignored and `xcb` exits 0 when it finds none. |

A test written from an approved schema goes in before the code that satisfies
it, so an assert can be red for a while by design — a specification waiting to
be met rather than a regression. All seventeen scripts are green as of this
commit; a red assert names its row, and that row's "Стан у коді" column says
where it stands.

## DEBUG logs

Every layer in the package prints through one mechanism —
`debugLog(tag:level:_:)` in `Sources/IntegrationKit/Support/DebugLog.swift` —
and every line is **silent in a Release build**: the gate is `#if DEBUG`
inside `debugLog` itself, not at each call site, so no line added to any
service needs a switch of its own and none of them reaches a shipping
build's console. Each line carries a `[IntegrationKit][ServiceName]` prefix
so it can be traced to one layer without reading the message, and an
`[error]` marker for the failure lines.

**What gets printed, service by service:**

- **Adapty** — every configuration step, every flow load, and (since 0.7.1)
  the **paywall's remote config itself** — the JSON a screen actually reads,
  not just "loaded" — every `getRemoteValue`/`remoteValue` call with the
  value it resolved to, and every product list load (both the flow's own
  load and a placement's `products(placement:)`) with the **full field set**
  per product — price, currency, subscription period, and the offer Adapty
  resolved (type, period, price) — not just the id.
- **StoreKit** — the same full field set for every raw `Product.products(for:)`
  answer, before anything in the package merges or caches it: price,
  currency, **region** (the pricing storefront the product was quoted in,
  not the device's own locale), the StoreKit product type
  (auto-renewable, non-renewable, …), the subscription period, and the
  introductory offer. Also: the device's `Storefront` (`countryCode`, `id`)
  and `Locale.current` once when the StoreKit layer comes up, and again on
  every `Storefront.updates` change — traced back to a pricing bug where a
  sandbox account StoreKit could not see priced from the wrong storefront,
  and a re-login moved the storefront mid-session without a new price
  request to reveal it. Diagnostic only, so unlike everything else on this
  list it is compiled out of a Release build entirely (`#if DEBUG` around
  the listener itself, not just the print) rather than left as an idle
  listener with nothing to print.
- **Premium (the arbiter)** — every purchase and restore outcome, and
  (since 0.7.1) the **resolved verdict** on every `apply` — `isPremium`,
  `source`, `isVerified`, `expiresAt` — including the line printed when an
  answer is dropped for arriving after a fresher one already landed
  (PM-06 row 2). `products(placement:completion:)` also prints one line per
  product in the list it is about to hand back — price, period, the
  introductory offer, and **which of the three sources answered for it**
  (StoreKit, Adapty, or the price cache) — PM-07's merge made readable.
  Since 0.10.0 `activeSubscriptionIds(completion:)` prints how many ids it
  found, or an `error` line for a timeout or an inactive layer.
- **PriceCache** (since 0.7.1) — how many prices came in fresh on a merge
  and how many carried an old introductory offer forward, and how many of
  the ids a screen asked for only the cache remembered.
- **AppsFlyer, Amplitude, Remote Config (Firebase)** — configuration, every
  event and user property, every conversion-data and deep-link callback.
- **Firebase Analytics** (since 0.8.0) — the direction of the collection flag
  and why, one line per event, user property and user id handed to Firebase,
  every name or key it was **not** sent under with the reason (an `error`
  line), every value cut with both lengths (an `info` line), every read of the
  instance id including `nil`, and every transaction sent. Search the console
  for `[IntegrationKit][FirebaseAnalytics]`.

**What never gets printed:** API keys, dev keys, tokens, receipts — every
credential is logged as `"set"`/`"empty"` only, never its value. A remote
config's JSON is printed in full because it is paywall content, not a
secret, capped at roughly 2 KB per line so one oversized dashboard blob
cannot push everything above it out of the console — a config longer than
that ends in `…truncated`.

**Reading it from a test, without a running app:** `debugLogSink` in
`DebugLog.swift` is the same hook `Checks/` uses to assert on a specific
trace instead of parsing `print` output — set it to a closure and every line
described above also reaches it, in a Release build too.

**Real output**, captured from the package's own `Checks/` scripts, plus
(for the StoreKit line only — `Product` has no public initializer, so no
harness can fabricate one; see [The StoreKit side](#the-storekit-side)) a
real device fetch:

Paywall config and `remoteValue`, from `Checks/adapty-service-check.sh`
(`AdaptyServiceCheck.swift`, AD-07):

```
[IntegrationKit][AdaptyService] remote config 'main' locale 'de': {"title":"Hallo"}
[IntegrationKit][AdaptyService] remote config 'main' locale 'en': {"title":"Hello"}
[IntegrationKit][AdaptyService] flow loaded for 'main'
[IntegrationKit][AdaptyService] products loaded for 'main': 1 — ["year.sub"]
[IntegrationKit][AdaptyService] remoteValue 'main'.'title' → Hello (String)
```

Every product line now carries the full field set, not just the id — one
entry per product, across the three layers that touch a price:

```
[IntegrationKit][AdaptyService] products loaded for 'main': 1 — ["year.sub: $39.99 (39.99 USD), period 1 year, offer freeTrial 1×1 week at $0.00"]
[IntegrationKit][StoreKitService] mindvox_week_free_trial: $4.99 (4.99 USD), region US, type Auto-Renewable Subscription, period 7 Day, introOffer FreeTrial 1×3 Day at $0.00
[IntegrationKit][PremiumService] year.sub: $39.99 (39.99 USD), period 1 year, intro freeTrial 1×1 week at $0.00, source StoreKit
```

The premium verdict and the price cache, from `Checks/test-mode-check.sh`
(`FakeAdaptySource` / `FakeAppleStore`, PM-06):

```
[IntegrationKit][PremiumService] start: seeded cache isPremium false, source none — asking sources now
[IntegrationKit][PremiumService] apply: isPremium false, source none, verified false, expires never (gen 1)
[IntegrationKit][PriceCache] merge: 1 fresh price(s), 0 carried an old introductory offer
[IntegrationKit][PremiumService] apply: isPremium true, source apple, verified false, expires 2026-10-18 12:32:26 +0000 (gen 2)
[IntegrationKit][PremiumService] purchase 'sub.month' on 'main' → purchased, didPay true
[IntegrationKit][PremiumService] apply: generation 2 dropped — generation 3 already applied
```

## Troubleshooting

**Start here:** print `kit.configurationIssues`. Every cause the package could
not work around and no retry will fix writes one line into it — an empty or
malformed key, a device id that arrived too late, a placement that does not
exist, a product the paywall does not sell, a profile attribute Adapty refused,
a profile that never arrived, crash reports filed before Firebase was up, an
install attribution AppsFlyer could not deliver. Most of the entries below have
a line waiting in there already.

```swift
kit.configurationIssues.forEach { print("[IntegrationKit] \($0)") }
```

No `#if DEBUG` around it: the list is filled in a **release** build too, which
is the whole reason it exists — the DEBUG log dies with the Xcode session, and
these causes are exactly the ones a tester hits on a TestFlight build. The same
list is also reachable as `kit.premium.configurationIssues`; both read one
package-wide store, deduplicated by text, oldest first. Shipping it as a
Crashlytics non-fatal at launch turns "the SDK is silent" into a searchable
dashboard entry.

- **An event is in Amplitude but not in Firebase.** Search the console for
  `[IntegrationKit][FirebaseAnalytics][error]`: the usual cause is a name or key
  Firebase would drop (a reserved name such as `first_open`, a `firebase_`,
  `google_` or `ga_` prefix, a character outside `A-Za-z0-9_`, more than 40
  characters) — the package does not send it, and the line names it. The other
  causes, in order of likelihood: Firebase was not up (the line is in
  `configurationIssues`), the run was a test run (nothing is sent by design),
  and collection was switched off on the device (a test run writes `false`; the
  next normal launch writes `true`, but only from that launch on).
- **The app crashes with `unrecognized selector sent to instance` on a tagged
  pointer, somewhere under `SwiftyStoreKit`.** Fixed in 0.5.0 — upgrade. The
  selector and the class in the message are meaningless (`-[__NSTaggedDate
  count]` and the like): they name whatever garbage the corrupted dictionary
  storage happened to hold. Nothing in the app causes it and nothing in the app
  fixes it — calling from the main thread does not help, because the package
  wrapped these calls in its own `Task` before reaching the SDK. See
  [The StoreKit side](#the-storekit-side).
- **`hasPaywall(placement:)` is always `false`.** Either the placement was
  never in `placements` at `configure` time, or the placement id does not
  match the Adapty dashboard exactly (case-sensitive, no trailing
  whitespace).
  `paywallState(placement:)` says which of the two it is: `.loading` means the
  request is still in flight or scheduled, `.unavailable` means it is never
  coming.
- **`products(placement:)` returns an empty array on a paywall that has
  products in the dashboard.** Usually a wrong `adaptyKey` — a key copied
  from a different app or a different Adapty project resolves placements
  that do not exist. Confirm the key against this app's Adapty dashboard, not
  a sibling app's.
- **Nothing Adapty-related happens at all, and there are no errors.** Check
  `configurationIssues` for a line about the key: an empty key, or one that
  does not start with `public_live` and run to at least 41 characters, leaves
  the whole layer inert by design. An app that ships its keys obfuscated is
  most likely decrypting this one wrong.
- **A purchase "fails" but the user was charged.** `.pending` is not `.failed`.
  If the UI collapses the five `PurchaseOutcome` cases into two, an Ask to Buy
  request still waiting for a parent reads as an error and the user is invited
  to make a second one. Handle `.pending` as waiting, and wait for
  `.premiumDidChange`. A user who really was charged and whose confirmation was
  lost is picked up without the app doing anything — by Adapty's profile push
  and by the payment queue at the next launch — so it never has to guess.
- **`isPremium` stays `false` after a real purchase.** Check `levels` at
  `configure` time against the Adapty access level id actually granted by
  the paywall — a mismatch here means a genuinely successful Adapty purchase
  never counts as premium from this package's point of view.
- **ATT dialog never shows.** `NSUserTrackingUsageDescription` missing from
  Info.plist, or `requestTrackingAuthorization` called before the app is
  fully foregrounded. Confirm you're calling
  `IntegrationKit.updateTrackingAuthorization(_:)` from the completion
  handler, and that the request itself isn't skipped in a debug/simulator
  build.
- **AppsFlyer never fires `handleContinue`/`handleOpen`.** Confirm
  `appsFlyerDevKey` is non-empty — an empty dev key silently skips creating
  AppsFlyer entirely, and both forwards become no-ops. Separately, Universal
  Links additionally need the Associated Domains capability configured, or
  iOS never calls `application(_:continue:restorationHandler:)` at all.
- **A campaign's deep links resolve, but the app never sees a value.** Read
  `kit.droppedDeepLinks`: anything above zero means the SDK reported "found"
  and handed over an empty payload that many times. Nothing on the app side
  fixes it — check the OneLink configuration for links that carry no
  `deep_link_value`.
- **Crashlytics dashboard shows unsymbolicated crashes.** The dSYM Run
  Script (setup step 5) is missing or its `inputPaths` point at the wrong
  target.
- **Non-fatals never reach the Crashlytics dashboard.** Read
  `kit.crashes.droppedReports`: anything above zero means
  `FirebaseIntegration.configure(isDebug:)` ran after
  `IntegrationKit.configure(...)`, or not at all, and every report filed in
  between was dropped. If it is zero, see the next entry.
- **The Crashlytics dashboard is empty on a device that ran a debug build,
  even now that the app is a release one.** Expected, and it clears itself.
  The debug launch wrote collection *off* into `NSUserDefaults`
  (`com.crashlytics.data_collection`), where it survived the reinstall; the
  first release launch writes `true` back, and the flag applies from the launch
  after that. So: launch the release build twice before concluding anything.
  What would make this permanent is a build that only ever writes `false` —
  which is why the package sets the flag explicitly on every launch, in both
  directions, rather than only when switching collection off.
- **Analytics, paywalls and attribution are all silent at once, and the keys
  are right.** `isTestsRunning` was left `true`. It is one switch over three
  SDKs, so "Amplitude is quiet" and "no paywall ever loads" and "AppsFlyer
  never attributes" arrive together — the usual cause is a launch argument or
  scheme setting that survived a debugging session, or a computed value that
  went constant. `kit.configurationIssues` names it directly: three lines, one
  per layer, each saying the app reported a test run. Firebase stays up in that
  state, so crashes still arrive and the app does not look dead — though
  Firebase **Analytics** is silent too, with its collection switched off until
  the next normal launch writes it back on.
- **A device that ran UI tests shows premium in a normal launch.** A test run's
  fake purchase stayed in the keys the live launch reads, with no expiry, and
  Adapty never takes premium away. From 0.9.1 the first live launch after a test
  run wipes it, and `configurationIssues` carries one line saying so. A device
  that leaked under an older version carries no mark — reinstall the app there
  once.
- **A report is in the dashboard but cannot be filtered by its tag.** Filter on
  the custom key `ik_tag`, not on the `info` dictionary: `info` is the report's
  `userInfo` and is only visible inside an issue that is already open.

## Readiness checklist

- [ ] Package added via SPM, product `IntegrationKit`
- [ ] `GoogleService-Info.plist` — this app's own, target membership checked
- [ ] Crashlytics dSYM Run Script added, `inputPaths` point at this target
- [ ] `NSUserTrackingUsageDescription` set in Info.plist
- [ ] `-ObjC` in the target's Other Linker Flags (Firebase Analytics)
- [ ] The app's own `Analytics.logEvent` calls moved to `kit.analytics.logEvent`,
      and no event is named after one of Firebase's reserved names
      (`first_open` included — `firstOpenEvent` too)
- [ ] Associated Domains added, if Universal Links are needed
- [ ] `AppDelegate` calls `FirebaseIntegration.configure(isDebug:)` before
      `IntegrationKit.configure(...)`, and both get the same `isDebug`
- [ ] `isTestsRunning` is computed from `-uitest` / `XCTestConfigurationFilePath`
      and is `false` on a real launch — check `kit.configurationIssues` for the
      three "test run" lines
- [ ] `productIds` lists every subscription id the paywall can sell
- [ ] `handleContinue`/`handleOpen` forwarded through `kit`, not any SDK
      directly
- [ ] `deviceId` is one stable id, the same value across app launches
- [ ] Amplitude key, Adapty key, AppsFlyer dev key — real keys for this app,
      not copied from another one
- [ ] AppsFlyer App ID confirmed against App Store Connect, not guessed
- [ ] `levels` matches the Adapty access level id actually granted by the
      paywall
- [ ] Every Remote Config key the app reads has an entry in
      `remoteConfigDefaults`, and each default is the value that is safe to ship
      — a key without one reads as `false`/`""`/`0`, indistinguishable from a
      value the console sent
- [ ] `kit.premium.purchase(...)` handles all five `PurchaseOutcome` cases —
      `.pending` shows waiting, `.unavailable` hides the button
- [ ] Every screen that gates content on premium observes `.premiumDidChange`
      rather than reading `isPremium` once. The flag moves without the app
      asking — an Adapty profile push, a purchase the payment queue delivers at
      the next launch — and a screen that only read it at `viewDidLoad` keeps
      paywalling a user who has already paid
- [ ] `kit.configurationIssues` is empty on a real launch, and
      `kit.crashes.droppedReports` and `kit.droppedDeepLinks` are zero (all
      three are readable in release — print them, or ship them as a
      Crashlytics non-fatal)
- [ ] The `IntegrationKit` returned by `configure` is stored for the lifetime
      of the process, not discarded — the `private var kit` in the AppDelegate
      example is a requirement, and the paragraph under it says what goes when
      it is dropped
- [ ] `for s in Checks/*.sh; do "./$s"; done` — all seventeen green (the last
      is the BuildHost build, so there is nothing to run separately)
