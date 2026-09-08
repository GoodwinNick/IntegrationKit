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
- [Analytics](#analytics)
- [Crash reporting](#crash-reporting)
- [Premium](#premium)
- [The StoreKit side](#the-storekit-side)
- [Deep links](#deep-links)
- [Building and checks](#building-and-checks)
- [Troubleshooting](#troubleshooting)
- [Readiness checklist](#readiness-checklist)

## Setup from scratch

### 1. Add the package

Xcode → File → Add Package Dependencies → this repo's URL → product
`IntegrationKit`.

```swift
.package(url: "https://github.com/GoodwinNick/IntegrationKit", from: "0.2.0")
```

The target's minimum deployment target must be iOS 15.6 or the package will
not build.

### 2. Add `GoogleService-Info.plist`

Your own Firebase project's config file (Firebase console), dropped into the
target's root with **target membership checked**. Without it,
`FirebaseIntegration.configure()` calls `FirebaseApp.configure()`, which
fails fatally at launch — there is no soft-fail path.

### 3. `Info.plist` / build settings

None of these are set by the package — all of them are app-side (modern Xcode
keeps them as `INFOPLIST_KEY_*` build settings rather than literal
`Info.plist` rows):

| Key | Why | Used by |
|---|---|---|
| `NSUserTrackingUsageDescription` | Required for the ATT dialog — without it `ATTrackingManager.requestTrackingAuthorization` shows nothing | ATT / AppsFlyer / Amplitude IDFA |

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

### 6. Call `FirebaseIntegration.configure()`, then `IntegrationKit.configure(...)`

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
		FirebaseIntegration.configure()

		let kit = IntegrationKit.configure(
			deviceId: AppDefaults.deviceId,
			amplitudeKey: ObfuscatedSecret.reveal(encrypted: SDKKeys.amplitudeEncrypted, secret: SDKKeys.secret),
			adaptyKey: ObfuscatedSecret.reveal(encrypted: SDKKeys.adaptyEncrypted, secret: SDKKeys.secret),
			placements: ["main", "onboarding"],
			sessionsCounter: AppDefaults.sessionsCounter,
			sharedSecret: ObfuscatedSecret.reveal(encrypted: SDKKeys.sharedSecretEncrypted, secret: SDKKeys.secret),
			productIds: ["year.sub", "week.sub"],
			levels: ["premium"],
			firstOpenEvent: "first_open",
			appsFlyerDevKey: ObfuscatedSecret.reveal(encrypted: SDKKeys.appsFlyerEncrypted, secret: SDKKeys.secret),
			appsFlyerAppId: "1234567890"
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
}
```

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

## `IntegrationKit.configure`

```swift
public static func configure(
	deviceId: String,
	amplitudeKey: String,
	adaptyKey: String,
	placements: [String],
	sessionsCounter: Int,
	sharedSecret: String,
	productIds: Set<String>,
	levels: Set<String> = ["premium"],
	firstOpenEvent: String? = nil,
	appsFlyerDevKey: String = "",
	appsFlyerAppId: String = ""
) -> IntegrationKit
```

| Parameter | What it is | Where it comes from | If you don't pass it |
|---|---|---|---|
| `deviceId` | One stable id, shared by Amplitude, Adapty and AppsFlyer so all three describe the same user | An app-generated/stored UUID, stable across launches | Required — no default. Amplitude, Adapty and AppsFlyer end up describing different users. |
| `amplitudeKey` | Amplitude project API key | Amplitude dashboard, per app | Required — no default. Amplitude never activates. |
| `adaptyKey` | Adapty public SDK key (`public_live_...`) | Adapty dashboard, per app | Required — no default. Adapty never activates, so premium can only ever come from the App Store receipt. |
| `placements` | Adapty placement ids to preload paywalls/products for | Adapty dashboard, per app | An empty array means no placement is warmed up — `hasPaywall`/`products` for any placement return empty until Adapty is asked directly through a refresh. |
| `sessionsCounter` | The app's own session counter, incremented once per launch before this call | App-owned persistent counter | Required — no default. Written into the Adapty profile as-is; passing a stale or constant value just means that field in the profile stops being meaningful. |
| `sharedSecret` | App Store Connect shared secret, used to validate the receipt against Apple's production endpoint | App Store Connect → Subscriptions → App-Specific Shared Secret | Required — no default, but `""` is legal and means the receipt is never checked (`checkReceipt` answers "not checked"). Premium then relies on Adapty alone. |
| `productIds` | The subscription product ids to look for in the receipt, and the ids whose prices are read from the store | App Store Connect, same ids as in the Adapty dashboard | Required — no default. An empty set means the receipt is read but nothing is ever found in it, so Apple can never confirm premium. |
| `levels` | The set of Adapty access level ids that count as "premium" | Adapty dashboard — access level ids configured for the paywall | Defaults to `["premium"]`. Wrong values here mean a real Adapty premium purchase never flips `isPremium` to true. |
| `firstOpenEvent` | Analytics event name logged exactly once per install | App's own event naming | `nil` (default) — no first-open event is logged at all. |
| `appsFlyerDevKey` | AppsFlyer dev key | AppsFlyer dashboard, per app | Defaults to `""`. An empty dev key means **AppsFlyer is not created at all** — no attribution, `kit.handleContinue`/`kit.handleOpen` become no-ops. |
| `appsFlyerAppId` | Numeric App Store id | App Store Connect / `itunes.apple.com/lookup` | Defaults to `""`. Only meaningful together with a non-empty `appsFlyerDevKey`; without a confirmed App ID, AppsFlyer attribution can end up pointed at the wrong app. |

The returned `IntegrationKit` exposes exactly three things to build UI on top
of: `premium: PremiumServicing`, `analytics: AnalyticsTracking`,
`crashes: CrashReporting`. Everything AppsFlyer- or Adapty-specific
(`AdaptyService`, `AppsFlyerService`, and their internal protocols) stays
behind the facade — the app cannot reach them even by trying, since 0.2.0
they are not public types.

## Analytics

```swift
public protocol AnalyticsTracking: AnyObject {
	func configure(apiKey: String, deviceId: String, firstOpenEvent: String?)
	func logEvent(_ event: String, properties: [String: Any]?)
	func setUserProperties(_ properties: [String: Any])
	func setUserId(_ userId: String)
	var deviceId: String? { get }
	func updateTrackingAuthorization(_ status: ATTrackingManager.AuthorizationStatus)
}
```

`configure` is already called for you inside `IntegrationKit.configure(...)`
— the app never calls it itself. `logEvent(_:)` without properties is
available through a protocol extension:

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

**ATT.** Forward the tracking authorization result through the facade, not
directly to Amplitude — it also reaches Adapty's attribution:

```swift
ATTrackingManager.requestTrackingAuthorization { status in
	kit.updateTrackingAuthorization(status)
}
```

`IntegrationKit.updateTrackingAuthorization(_:)` calls
`analytics.updateTrackingAuthorization(_:)` (which attaches Amplitude's IDFA
plugin once the answer is `.authorized`) and Adapty's own ATT status update,
in that order.

**First-open event.** Pass a name through `firstOpenEvent` at `configure`
time and the package logs it once per install, gated internally so a
reinstall or a relaunch never double-logs it. Pass `nil` to opt out.

## Crash reporting

```swift
public protocol CrashReporting {
	func recordNonFatal(_ tag: String, _ error: Error, _ info: [String: Any])
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

## Premium

`PremiumServicing` is the single entry point for paywalls, products,
purchases and the current premium flag. Adapty and the Apple receipt are
both internal to the implementation behind it.

```swift
public protocol PremiumServicing: AnyObject {
	var isPremium: Bool { get }
	func start()
	func refresh()
	func restore(completion: @escaping (RestoreOutcome) -> Void)
	func purchase(_ productId: String, placement: String, completion: @escaping (PurchaseOutcome) -> Void)
	func product(_ productId: String, placement: String, completion: @escaping (PremiumProduct?) -> Void)
	func products(placement: String, completion: @escaping ([PremiumProduct]) -> Void)
	func hasPaywall(placement: String) -> Bool
	func remoteValue<T>(placement: String, key: String) -> T?
	func logPaywallOpen(placement: String)
}
```

`start()` is already called once by `IntegrationKit.configure(...)` — the app
never calls it. `isPremium` is synchronous and reads from cache, no network
round trip; the source of truth behind it is Adapty first, the App Store
receipt as a fallback when Adapty has not answered yet.

### The paywall-to-purchase flow

```swift
func paywall() {
	kit.premium.logPaywallOpen(placement: "main")

	let title: String? = kit.premium.remoteValue(placement: "main", key: "title")
	let paywallExists = kit.premium.hasPaywall(placement: "main")

	kit.premium.products(placement: "main") { products in
		for product in products {
			print(product.localizedTitle, product.localizedPrice)
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
- **`remoteValue<T>(placement:key:)`** — reads a value out of the paywall's
  remote config by key; returns `nil` if the placement, the key, or the type
  cast does not match.
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
- **`restore(completion:)`** — restores through both sources (StoreKit, then a
  re-ask of Adapty) and reports one combined `RestoreOutcome`. `isPremium`
  already reflects `.restored` by the time the completion fires.
- **`refresh()`** — re-asks both sources and updates the cached state; safe
  to call any time (e.g. on foreground), concurrent calls collapse into one.

### Models

```swift
public struct PremiumProduct: Equatable, Sendable {
	public let id: String
	public let localizedTitle: String
	public let localizedPrice: String
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
	case cancelled
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
leaves the package, it always resolves to one of these three/three cases
before reaching the app.

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
(`Sources/IntegrationKit/StoreKit/`, built on `SwiftyStoreKit`), and the app's
whole contribution is two `configure` arguments: `sharedSecret` and
`productIds`. `AppleSubscribing`, which earlier releases asked the app to
implement, is internal now.

What the package does with them:

- **Receipt validation** — `AppleReceiptValidator(service: .production)` with
  your shared secret, then an auto-renewable check for each of `productIds`.
  Three answers, and the difference matters: `true` (an active subscription is
  in the receipt), `false` (the receipt was read and carries none), `nil` (it
  could not be checked at all). Only `false` can revoke premium.
  A **sandbox receipt answers `nil` immediately** — the production endpoint can
  only ever reply 21007 to one, so TestFlight and simulator builds simply lean
  on Adapty. An empty `sharedSecret` answers `nil` the same way.
- **Restore** — `restorePurchases(atomically: true)`, unfinished transactions
  finished. Anything restored is `.restored`, even if some other purchase in
  the same batch failed.
- **The fallback purchase** — `purchaseProduct(atomically: true)`, run by
  `PremiumServicing.purchase(_:placement:completion:)` itself when Adapty's own
  request asks for a StoreKit retry. The app never sees the retry, only the
  final `PurchaseOutcome`.
- **Interrupted transactions** — `completeTransactions(atomically: true)` runs
  once at `configure` time and finishes whatever was left stuck in the payment
  queue (app killed mid-payment, ask-to-buy approved later). If something was
  actually delivered, the premium state is re-asked in the same launch.
- **Prices** — `retrieveProductsInfo` for the ids Adapty listed on the
  placement; see the note under `products(placement:)` below.

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
- If `appsFlyerDevKey` was empty at `configure` time, both methods are
  effectively no-ops — there is no AppsFlyer instance behind them to forward
  to.

**What the package does with a resolved deep link:** logs an
`af_didResolveDeepLink` analytics event, sets a `deep_link_value` user
property, and writes the same value into the Adapty profile. It does not
navigate anywhere. If the app needs to open a specific screen based on the
resolved deep link value, that routing is entirely the app's own code —
`IntegrationKit` has no callback for "the deep link resolved to X".

## Building and checks

The package does not build standalone — `swift build` targets the macOS host
and fails on iOS-only dependencies, and running `xcodebuild` directly is
blocked by the local build hook. Verification goes through `BuildHost/`, a
minimal iOS app on xcodegen that links the package:

```bash
cd BuildHost && xcb app-sim
```

Changed `BuildHost/project.yml`? Run `xcodegen generate` first.

`Checks/` are self-checks that compile pure Swift types directly with
`swiftc` — no XCTest, no Xcode project, no SDK imports:

```bash
./Checks/premium-resolver-check.sh
```
Compiles `PremiumResolver` plus `PremiumAccess`/`PremiumState`/`PremiumSource`
and runs assertions on the arbitration order: a verified Adapty answer beats
the cache in both directions; a false receipt does not revoke an unverified
local purchase; a stale cache plus a true receipt yields unverified state
with no `expiresAt`; silence everywhere yields `.free`.

```bash
./Checks/premium-barrier-check.sh
```
Compiles `PremiumService` against a stub `Adapty` module (built first as a
static library so the real SDK is never linked) and checks the `refresh()`
concurrency barrier, the StoreKit-fallback path, and the price merge — the
store's price winning where it answered, Adapty's kept where it did not.

```bash
./Checks/appsflyer-attribution-check.sh
```
Compiles `AppsFlyerAttributionMapping` and checks that `NSNull`/non-scalar
values and non-string keys are dropped from `cleanedAttributionData`; that an
empty input stays empty; that a `nil` deep link value becomes `"-"`; that
`clickEvent` fields flow through into the payload.

## Troubleshooting

- **`hasPaywall(placement:)` is always `false`.** Either the placement was
  never in `placements` at `configure` time, or the placement id does not
  match the Adapty dashboard exactly (case-sensitive, no trailing
  whitespace).
- **`products(placement:)` returns an empty array on a paywall that has
  products in the dashboard.** Usually a wrong `adaptyKey` — a key copied
  from a different app or a different Adapty project resolves placements
  that do not exist. Confirm the key against this app's Adapty dashboard, not
  a sibling app's.
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
- **Crashlytics dashboard shows unsymbolicated crashes.** The dSYM Run
  Script (setup step 5) is missing or its `inputPaths` point at the wrong
  target.

## Readiness checklist

- [ ] Package added via SPM, product `IntegrationKit`
- [ ] `GoogleService-Info.plist` — this app's own, target membership checked
- [ ] Crashlytics dSYM Run Script added, `inputPaths` point at this target
- [ ] `NSUserTrackingUsageDescription` set in Info.plist
- [ ] Associated Domains added, if Universal Links are needed
- [ ] `AppDelegate` calls `FirebaseIntegration.configure()` before
      `IntegrationKit.configure(...)`
- [ ] `sharedSecret` is this app's real App Store Connect shared secret, and
      `productIds` lists every subscription id the paywall can sell
- [ ] `handleContinue`/`handleOpen` forwarded through `kit`, not any SDK
      directly
- [ ] `deviceId` is one stable id, the same value across app launches
- [ ] Amplitude key, Adapty key, AppsFlyer dev key — real keys for this app,
      not copied from another one
- [ ] AppsFlyer App ID confirmed against App Store Connect, not guessed
- [ ] `levels` matches the Adapty access level id actually granted by the
      paywall
- [ ] `./Checks/premium-resolver-check.sh`, `./Checks/premium-barrier-check.sh`
      and `./Checks/appsflyer-attribution-check.sh` all pass
- [ ] `cd BuildHost && xcb app-sim` builds
