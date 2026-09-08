# IntegrationKit — детальний гайд по інтеграції

Джерела фактів: код пакета (`Sources/IntegrationKit/*.swift`), скіли інтеграцій
(`~/.claude/skills/{firebase,amplitude,appsflyer}-integration`, `adapty-premium`,
`analytics-events`) і живий еталон `video-to-mp3` (`VideoToMp3/Core/AppDelegate.swift` та
`VideoToMp3/Services/*.swift`). Де вимога береться зі скіла чи еталона, а не з коду пакета —
позначено окремо.

## Зміст

- [Підключення з нуля](#підключення-з-нуля)
- [Firebase](#firebase)
- [Amplitude](#amplitude)
- [Adapty](#adapty)
- [AppsFlyer](#appsflyer)
- [Преміум](#преміум)
- [Deep linking](#deep-linking)
- [Тести](#тести)
- [Граблі](#граблі)
- [Перевірки](#перевірки)
- [Чекліст готовності](#чекліст-готовності)

## Підключення з нуля

### 1. Додати пакет

Xcode → File → Add Package Dependencies → url цього репо → продукт `IntegrationKit`.
Мінімальна платформа таргета — iOS 15.6 (нижче пакет не збереться).

### 2. Покласти файли в проєкт

- **`GoogleService-Info.plist`** — свій Firebase-проєкт на кожну апку (Firebase-консоль,
  акаунт `text.alex.erko` — вимога зі `Skill(firebase-integration)`, у коді пакета не
  видно). Файл — у корінь таргета, і **обов'язково перевірити target membership**: без
  нього `FirebaseApp.configure()` мовчки не знайде конфіг.
- **`Configuration.storekit`** (опційно, для дебага Adapty-покупок) — Xcode → File → New →
  File → StoreKit Configuration File, з реальними product id апки. Прописується у
  Debug-схемі (Run → Options → StoreKit Configuration) і в кожному тест-плані. Вимога зі
  `Skill(adapty-premium)`, п. 8 — без нього симулятор на першому зверненні до StoreKit
  показує системний алерт входу в App Store акаунт, який деактивує апку (в еталоні
  video-to-mp3 через це намертво зависав ATT-запит).

### 3. Info.plist / build settings

Жоден із цих ключів пакет не ставить — усі на боці апки (сучасний Xcode тримає їх як
`INFOPLIST_KEY_*` build settings, а не окремі рядки в `Info.plist`-файлі):

| Ключ | Навіщо | Приклад значення з еталона |
|---|---|---|
| `NSUserTrackingUsageDescription` | ATT-діалог (без нього `requestTrackingAuthorization` не показує вікно) | `"Allowing tracking helps us personalize your experience and show content that matches your interests."` (video-to-mp3) |

### 4. Capabilities

- **Associated Domains** — тільки якщо апка приймає Universal Links через AppsFlyer OneLink
  (`applinks:<app>.onelink.me` або власний домен з AppsFlyer). У video-to-mp3 цієї
  capability ще немає — деплінки в еталоні йдуть тільки через URL-схему. Без Associated
  Domains `application(_:continue:restorationHandler:)` просто не викликається системою.
- URL-схема для legacy-деплінків — стандартний `CFBundleURLTypes` в Info.plist (Xcode →
  таргет → Info → URL Types), окремо від пакета.

### 5. Run Script — dSYM для Crashlytics

Обов'язково для Crashlytics, інакше креші в дашборді не символізуються. Фаза «Run Script»
після Compile Sources, точно за еталоном video-to-mp3 (`project.pbxproj`):

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

`checkouts/firebase-ios-sdk` тут — SPM-чекаут у `SourcePackages` **самого хост-таргета**
(не пакета): оскільки `IntegrationKit` тягне `firebase-ios-sdk` транзитивно, він
з'являється там автоматично після резолву залежностей.

### 6. Порядок ініціалізації

Фіксований: **Firebase → Amplitude → Adapty → PremiumService → AppsFlyer**. Причина —
`AdaptyService.configure()` лінкує Amplitude-ідентичність усередині себе
(`linkAmplitudeUserId`), тож Amplitude має вже мати `deviceId` виставленим; AppsFlyer з
атрибуцією пише в Adapty-профіль, тож Adapty має бути активований раніше.

### 7. Повний AppDelegate

За живим еталоном `video-to-mp3` (`VideoToMp3/Core/AppDelegate.swift`), переписаний на
типи пакета замість прямих SDK-викликів:

```swift
import UIKit
import IntegrationKit

@main
class AppDelegate: UIResponder, UIApplicationDelegate {

	static var window: UIWindow?
	let rootRouter = RootRouter()

	// SDKKeys, AppDefaults, appOwnedReceiptChecker — на боці апки, не пакета.
	private let analytics: AnalyticsTracking = AmplitudeAnalytics()
	private let adapty = AdaptyService()
	private lazy var appsFlyer: AppsFlyerServicing = AppsFlyerService(analytics: analytics, adapty: adapty)
	private lazy var premium = PremiumService(adapty: adapty, apple: appOwnedReceiptChecker)

	func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
		#if DEBUG
			UITestMode.applyLaunchState()
		#endif

		// 1. Firebase — гард на plist, апка вирішує сама (FirebaseIntegration.configure()
		// без нього впаде фатальною помилкою всередині FirebaseApp.configure()).
		if Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist") != nil {
			FirebaseIntegration.configure()
		}

		AppDefaults.sessionsCounter += 1

		// 2. Amplitude — deviceId ставиться до першої події, до Adapty.
		analytics.configure(apiKey: SDKKeys.amplitude(), deviceId: AppDefaults.deviceId, firstOpenEvent: "first_open_custom")

		// 3. Adapty — премум + атрибуція.
		adapty.configure(
			apiKey: SDKKeys.adapty(),
			customerUserId: AppDefaults.deviceId,
			sessionsCounter: AppDefaults.sessionsCounter,
			placements: ["main", "onboarding"],
			analytics: analytics
		)

		// 3b. Арбітраж преміуму — одразу після Adapty, PremiumService сам запитає обидва джерела.
		premium.start()

		// 4. AppsFlyer — devKey обфускований і живе в апці, appId підтверджений юзером.
		appsFlyer.configure(devKey: SDKKeys.appsflyer(), appId: "<AppsFlyer App ID>", deviceId: AppDefaults.deviceId)

		analytics.logEvent("app_launch")

		let window = UIWindow(frame: UIScreen.main.bounds)
		window.rootViewController = UIStoryboard(name: "LaunchScreen", bundle: .main).instantiateInitialViewController()
		window.makeKeyAndVisible()
		AppDelegate.window = window
		rootRouter.configure(window: window)
		rootRouter.toSplash()

		return true
	}

	func application(_ application: UIApplication, continue userActivity: NSUserActivity, restorationHandler: @escaping ([UIUserActivityRestoring]?) -> Void) -> Bool {
		appsFlyer.handleContinue(userActivity, restorationHandler: restorationHandler)
		return true
	}

	func application(_ app: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
		appsFlyer.handleOpen(url, options: options)
		return true
	}
}
```

`SDKKeys`, `AppDefaults`, `RootRouter`, `appOwnedReceiptChecker` — типи апки, не пакета;
у видаленому з еталона прикладі вони показують, звідки саме беруться значення, які пакет
приймає параметрами.

## Firebase

**Що робить:** ініціалізує Firebase Core і Crashlytics; у DEBUG вимикає збір крешів.
`FirebaseAnalytics` пакет свідомо не тягне (рішення 2026-09-03 з `Skill(firebase-integration)`:
DebugView непридатний для перевірки, аналітика в наборі апок — тільки Amplitude).

**Публічний тип:** `FirebaseIntegration.configure()` — без параметрів.

```swift
public enum FirebaseIntegration {
	public static func configure()
}
```

**Що дає апка:**
- `GoogleService-Info.plist` (свій Firebase-проєкт, у корені таргета, у target membership);
- гард на наявність plist перед викликом — інакше фатальна помилка на старті;
- Run Script для dSYM (розділ «Підключення з нуля», п. 5).

**Автоматично:** `Crashlytics.crashlytics().setCrashlyticsCollectionEnabled(false)` у DEBUG.

Для нефатальних помилок — окремий тип, не частина `FirebaseIntegration`:

```swift
public struct CrashReporter: CrashReporting {
	public func recordNonFatal(_ tag: String, _ error: Error, _ info: [String: Any])
}
```

Фільтрує мережевий шум сам (`NSURLErrorNotConnectedToInternet`, `NSURLErrorCancelled` не
летять у Crashlytics).

## Amplitude

**Що робить:** ініціалізує Amplitude SDK, ставить user id до першого івента, логує подію
першого відкриття один раз на інстал, додає IDFA-плагін після дозволу ATT.

**Публічний тип:**

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

Реалізація — `AmplitudeAnalytics`. `logEvent(_:)` без properties доступний через
protocol extension.

**Що дає апка:**
- прод API key з дашборда Amplitude (з Jira-задачі цієї апки — вимога зі скіла, у коді
  пакета ключ ніде не зашитий);
- стабільний `deviceId` — той самий, що йде в Adapty й AppsFlyer;
- `firstOpenEvent` — назву події першого відкриття (опційно, `nil` — не логувати).

**Автоматично:** маркування `environment: production/sandbox` на перший `identify`; догляд
за тим, щоб `firstOpenEvent` пішов рівно один раз (прапорець
`IntegrationKit.amplitude.firstOpenTracked` у `UserDefaults.standard`); `AmplitudeIDFAPlugin`
підвішується сам при `status == .authorized` через `updateTrackingAuthorization`.

Список подій (`LogEventKey` чи інший enum) — на боці апки; пакет приймає подію як `String`.

## Adapty

**Що робить:** активує Adapty, тягне пейволи й продукти для переданих плейсментів, пише
`launchSession`/`lastUsedDay`/деплінк у профіль, лінкує Amplitude-ідентичність, проводить
покупки, шле AppsFlyer-атрибуцію в Adapty.

**Публічні типи:**

```swift
public protocol AdaptyServicing: AnyObject {
	func configure(apiKey: String, customerUserId: String, sessionsCounter: Int, placements: [String], analytics: AnalyticsTracking)
	func setProfileValue(value: String, key: String)
	func hasPaywall(placement: String) -> Bool
	func hasProductsForPaywall(placement: String, id: String) -> Bool
	func hasProductsForPaywall(placement: String) -> Bool
	func getRemoteValue<Type>(placement: String, key: String) -> Type?
	func getAbValue(placement: String) -> Int?
	func getBoolValue(placement: String, key: String) -> Bool
	func logPaywallOpen(placement: String)
	func logOnboardingOpen(step: Int)
	func updateAttribution(attribution: [AnyHashable: Any])
	func buyProduct(placement: String, id: String, completion: ((AdaptyPurchaseResult) -> Void)?)
	func integrateFirebase(appInstanceId: String)
	func integrateFacebook(id: String)
	func updateAppTrackingTransparencyStatus(_ status: ATTrackingManager.AuthorizationStatus)
	func updateAppsFlyerAttribution(_ data: [AnyHashable: Any], networkUserId: String?)
}
```

Реалізація — `AdaptyService` (клас, не struct — тримає стан пейволів). Плейсменти й
access-level id — прості `String`: пакет не заводить enum, апка передає власні назви з
дашборда Adapty (на відміну від еталона AISONG, де `AdaptyPlacement` — власний enum апки;
у пакеті це узагальнено до `[String]`).

**Що дає апка:**
- Adapty public API key (`public_live_...`, з дашборда Adapty цієї апки — не переносити
  ключ іншої апки, вимога зі скіла);
- `customerUserId` — той самий стабільний id, що і в Amplitude/AppsFlyer;
- `placements` — id плейсментів з дашборда Adapty;
- `sessionsCounter` — власний лічильник сесій апки.

**Автоматично:** підписка на `Adapty.delegate` до `activate()` (щоб не пропустити перший
push профілю); лінк Amplitude user id/device id у профіль; запис `lastUsedDay` і
`launchSession`; підвантаження продуктів для кожного плейсменту.

`AdaptyPurchaseResult` (`success`/`cancelled`/`retryWithStoreKit`/`failed`) — сигнал
результату покупки; `retryWithStoreKit` означає, що сам запит до Adapty впав (офлайн, бад
продукт, серверна помилка) — це не рішення про преміум, а команда «спробуй StoreKit
напряму».

## Преміум

Чотири типи, разом — арбітр преміум-статусу апки.

```swift
public final class PremiumService {
	public init(
		store: PremiumStateStoring = UserDefaultsPremiumStore(),
		adapty: AdaptyPremiumProviding? = nil,
		apple: AppleReceiptChecking? = nil,
		levels: Set<String> = ["premium"]
	)
	public var isPremium: Bool { get }
	public func start()
	public func refresh()
	public func apply(adapty: PremiumAccess?)
	public func applyLocalPurchase()
	public func applyReceiptCheck(_ hasReceipt: Bool?)
}
```

```swift
public protocol AdaptyPremiumProviding: AnyObject {
	var premiumObserver: ((AdaptyProfile) -> Void)? { get set }
	func refreshPremium()
}
// AdaptyService конформить автоматично (AdaptyService+Premium.swift).

public protocol AppleReceiptChecking: AnyObject {
	func checkReceipt(completion: @escaping (Bool?) -> Void)
}
// Пакет НЕ реалізує — валідація рецепта лишається StoreKit-логікою апки
// (у video-to-mp3 — SwiftyStoreKit-based SubscriptionService, поза пакетом).

public protocol PremiumStateStoring: AnyObject {
	var cached: PremiumState? { get set }
	var premium: Bool { get set }
}
// Дефолт — UserDefaultsPremiumStore (ключі "premiumStateKey" / "premiumKey").
```

### Правило арбітражу

Вирішує чиста функція `PremiumResolver.resolve(adapty:apple:cached:now:) -> PremiumState`,
у порядку:

1. **Adapty відповів — він головний, завжди й в обидва боки.** Verified premium так само,
   як verified revoke: свіжий `false` від Adapty знімає преміум, навіть якщо кеш або
   Apple-рецепт кажуть інакше.
2. **Кеш, якщо ще валідний і (verified АБО premium).** Це і є свідоме рішення: непідтверджена
   Adapty покупка (щойно куплена локально, профіль ще не прийшов) тримається, поки Adapty
   не скаже своє — а не скидається одразу, як тільки Apple-рецепт відповість `false`.
   Рішення 2026-09-07: **«краще трохи доплатити за халявщика, ніж втратити преміум»** —
   це не баг, а обраний компроміс на користь юзера.
3. **Apple-рецепт як резерв**, якщо Adapty й валідний кеш мовчать. `apple == nil` означає
   «рецепт не перевірявся», а не «немає доступу» — це окремий стан, не `false`.
4. **Ніхто не відповів, кеш є** — повертає те, що було, але знімає прапорець `isVerified`.
5. Нічого немає взагалі — `PremiumState.free`.

Тобто **Adapty завжди переможе** — і коли дає преміум, і коли забирає. Локальний
StoreKit-рецепт ніколи не переб'є вже підтверджений Adapty-стан; його роль — тільки
заповнити паузу до першої відповіді Adapty (офлайн-старт, ще не активований профіль).

`PremiumService.start()` мігрує legacy-прапорець преміуму апки при першому запуску
(`store.cached == nil` → сідить кеш зі старого `store.premium`, `source: .legacy`), потім
підписується на `adapty?.premiumObserver` і викликає `refresh()`. `refresh()` захищений
від паралельних запусків прапорцями `awaitingAdapty`/`awaitingApple`: поки попередній
`refresh()` ще чекає відповіді, другий виклик — no-op. Увесь запис у сховище — під одним
`NSRecursiveLock`, щоб `cached` і дзеркальний `premium`-прапорець ніколи не розійшлися.

`Notification.Name.premiumDidChange` (`PremiumNotification.swift`) шлеться тільки коли
значення прапорця дійсно змінюється, на `DispatchQueue.main.async`.

## Deep linking

Пакет форвардить обидва системні виклики в AppsFlyer SDK і не більше:

```swift
public protocol AppsFlyerServicing: AnyObject {
	func configure(devKey: String, appId: String, deviceId: String)
	func handleContinue(_ userActivity: NSUserActivity, restorationHandler: @escaping ([UIUserActivityRestoring]?) -> Void)
	func handleOpen(_ url: URL, options: [UIApplication.OpenURLOptionsKey: Any])
}
```

- **Universal Links** (`application(_:continue:restorationHandler:)`) — потребують
  capability Associated Domains з `applinks:<домен AppsFlyer OneLink>` в Xcode-таргеті.
  Без неї система взагалі не викликає цей метод AppDelegate.
- **URL-схема** — реєструється окремо, стандартний `CFBundleURLTypes` в Info.plist, і йде
  через `application(_:open:options:)`.

Обидва форварди в `AppDelegate` — через методи сервіса (`handleContinue`/`handleOpen`), не
`AppsFlyerLib.shared()` напряму: інакше під `-uitest` SDK торкається в обхід стаба.

**Чесно про межі:** коли деплінк резолвиться, пакет виконує рівно це:

```swift
func applyDeepLink(deeplinkValue: String?, clickEvent: [String: Any]) {
	let (payload, dlvValue) = AppsFlyerAttributionMapping.deepLinkPayload(deeplinkValue: deeplinkValue, clickEvent: clickEvent)
	analytics.logEvent("af_didResolveDeepLink", properties: payload)
	analytics.setUserProperties(["deep_link_value": dlvValue])
	adapty.setProfileValue(value: dlvValue, key: "deep_link_value")
}
```

Тобто: **лог в аналітику + запис у профіль Adapty. Все.** Пакет нікуди не веде юзера — у
`AppsFlyerServicing` немає колбека назовні на резолвнутий деплінк. Якщо апці треба
відкрити конкретний екран за `deeplinkValue`, це рішення й код — повністю на боці апки
(власний обробник, що читає той самий `deeplinkValue`, який пакет уже проатрибутував і
залогував).

`AppsFlyerAttributionMapping` (чисті функції `cleanedAttributionData`/`deepLinkPayload`) —
винесено в окремий файл спеціально, щоб перевірятись без лінковки бінарного
`AppsFlyerLib` (див. «Перевірки»).

## Тести

Пакет не постачає жодного стаба — тільки протоколи (`AnalyticsTracking`, `AdaptyServicing`,
`AppsFlyerServicing`, `CrashReporting`, `AppleReceiptChecking`, `PremiumStateStoring`).
Підміна на UI-тестах — рішення й код апки: `#if DEBUG` + `UITestMode.isActive`-гард,
стаби пишуть лог у файл (патерн `AnalyticsStub` в еталонах), мережі нуль.

`PremiumService` тестується без окремого стаба — конструктор приймає протокол-типізовані
`adapty`/`apple`/`store`, юніт-тест підставляє власні спаї напряму через `init(...)`.

Правило з `Skill(xcuitest)` (інцидент AISONG 2026-08-26): тестовий гачок має бути
**невидимий поза `-uitest`** — або взагалі не компілюється поза DEBUG, або компілюється,
але `UITestMode.isActive` не дає йому активуватись. Стаб-ключі (`uitest-invalid-*-key`)
лишаються невалідними навіть якщо гард колись прибрати — друга лінія захисту.

## Граблі

- **Adapty ламає публічний API всередині мінорних версій.** 2.11 переробила
  `remoteConfig` на структуру — код, що читав його як словник, перестав компілюватись.
  Тому `Package.swift` пінить `Adapty`/`AdaptyUI` через `.upToNextMinor`, а не `from:`.
  AppsFlyer запінений так само, превентивно (бінарний xcframework, свіжа мінорна вже
  ламала попередній пакет).
- **`waitForATTUserAuthorization(timeoutInterval: 60)`.** Якщо ATT-діалог в апці не
  показався (запит стоїть не в `viewDidAppear`, або система вже деактивувала апку іншим
  алертом — вхід в App Store акаунт на симуляторі, дзвінок, Face ID), AppsFlyer чекає
  відповіді рівно 60 секунд перед стартом. Симптом ідентичний «SDK не стартує» — а
  причина за три кроки вбік.
- **Пакет не збирається сам по собі.** `swift build` цілиться в macOS-хост і падає на
  вимогах платформи; прямий `xcodebuild` закритий хуком. Перевірка йде через
  `BuildHost/` — мінімальну iOS-апку на xcodegen, яка лінкує пакет: `cd BuildHost && xcb
  app-sim`. Змінив `project.yml` → `xcodegen generate`.
- **AppsFlyer App ID — не вгадується.** Числовий App Store id, окремий від devKey.
  Кандидата можна знайти в самій апці (rate-us/share URL) або через
  `curl -s "https://itunes.apple.com/lookup?bundleId=<bundle id>"` (поле `trackId`), але
  **фінальне значення підтверджує юзер** — атрибуція на чужий id виявляється в дашборді
  через тижні, а не одразу.

## Перевірки

Дві self-перевірки без XCTest і без Xcode-проєкту — пряма `swiftc`-компіляція чистих
типів (жодних SDK-імпортів):

```bash
./Checks/premium-resolver-check.sh
```
Компілює `PremiumResolver` + `PremiumAccess`/`PremiumState`/`PremiumSource` і ганяє 5
асертів: Adapty active перебиває кеш; Adapty inactive знімає навіть непідтверджену
покупку; `false`-рецепт НЕ знімає непідтверджену покупку (правило арбітражу з
2026-09-07); протухлий кеш + `true`-рецепт дає unverified без `expiresAt`; тиша всюди —
`.free`.

```bash
./Checks/appsflyer-attribution-check.sh
```
Компілює `AppsFlyerAttributionMapping` і ганяє 4 асерти: `NSNull`/нескалярні
значення/нестрокові ключі відкидаються з `cleanedAttributionData`; порожній вхід лишається
порожнім; `nil` deeplinkValue падає у `"-"`; поля `clickEvent` протікають у payload.

## Чекліст готовності

- [ ] Пакет додано через SPM, продукт `IntegrationKit`
- [ ] `GoogleService-Info.plist` — свій для цієї апки, у target membership
- [ ] Run Script для Crashlytics dSYM додано, `inputPaths` вказують на цей таргет
- [ ] `NSUserTrackingUsageDescription` виставлено в Info.plist
- [ ] Associated Domains додано, якщо потрібні Universal Links
- [ ] `AppDelegate`: Firebase (з гардом) → Amplitude → Adapty → `PremiumService.start()` →
      AppsFlyer, у цьому порядку
- [ ] Forwards `application(_:continue:restorationHandler:)` і `application(_:open:options:)`
      ідуть через методи сервіса AppsFlyer, не напряму в `AppsFlyerLib`
- [ ] Amplitude API key, Adapty API key, AppsFlyer devKey (обфускований) — реальні ключі
      цієї апки, не перенесені з іншої
- [ ] AppsFlyer App ID — підтверджений юзером, не вгаданий
- [ ] `deviceId` — один і той самий стабільний id у Amplitude/Adapty/AppsFlyer
- [ ] `AppleReceiptChecking` — або власний конформер апки, або свідомо `nil`
- [ ] Стаби для UI-тестів заведені в апці, невидимі поза `-uitest`
- [ ] `./Checks/premium-resolver-check.sh` і `./Checks/appsflyer-attribution-check.sh`
      зелені
- [ ] `cd BuildHost && xcb app-sim` — пакет лінкується і збирається
