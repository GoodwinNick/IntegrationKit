# IntegrationKit

Swift Package з обгортками чотирьох SDK — **Firebase** (Core + Crashlytics), **Amplitude**,
**Adapty**, **AppsFlyer** — плюс арбітраж преміум-статусу (`PremiumService`). Механіка
інтеграцій, однакова для будь-якої апки, живе тут; специфіка апки (ключі, події, плейсменти,
модель підписки) лишається в апці й приходить параметрами.

Детальний гайд по підключенню, кожній інтеграції, деплінкам, тестам і граблям —
[`docs/Integration.md`](docs/Integration.md). Цей файл — швидкий старт.

## Що входить

| SDK | Продукти | Пінінг у `Package.swift` |
|---|---|---|
| Firebase | `FirebaseCore`, `FirebaseCrashlytics` (без `FirebaseAnalytics`) | `from: "12.0.0"` |
| Amplitude | `AmplitudeSwift` | `from: "1.18.7"` |
| Adapty | `Adapty`, `AdaptyUI` | `.upToNextMinor(from: "2.10.4")` / `"2.1.5"` |
| AppsFlyer | `AppsFlyerLib` | `.upToNextMinor(from: "7.0.2")` |

Мінімальна платформа — iOS 15.6 (`swift-tools-version: 5.9`).

Adapty й AppsFlyer запінені `.upToNextMinor`, а не `from:` — обидва ламали публічний API
всередині мінорних версій. Деталі — у розділі «Граблі» довгого гайду.

## Підключення

```swift
.package(url: "https://github.com/GoodwinNick/IntegrationKit.git", from: "0.1.0")
```

В Xcode: File → Add Package Dependencies → та сама url, продукт `IntegrationKit`.

Що ще покласти в Xcode-проєкт (plist-файли, Run Script, ключі в Info.plist, capabilities) —
крок за кроком у [`docs/Integration.md`](docs/Integration.md#підключення-з-нуля).

## Швидкий приклад

```swift
import IntegrationKit

// 1. Firebase — Core + Crashlytics. Апка сама гардить на наявність plist.
if Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist") != nil {
	FirebaseIntegration.configure()
}

let crashReporter: CrashReporting = CrashReporter()
crashReporter.recordNonFatal("network", error)

// 2. Amplitude
let analytics: AnalyticsTracking = AmplitudeAnalytics()
analytics.configure(apiKey: apiKey, deviceId: deviceId, firstOpenEvent: "first_open")
analytics.logEvent("app_launch")

// 3. Adapty (premium + attribution sink). Concrete type, не протокол — конформить і
// AdaptyServicing, і AdaptyPremiumProviding (для PremiumService).
let adapty = AdaptyService()
adapty.configure(apiKey: apiKey, customerUserId: deviceId, sessionsCounter: sessionsCounter, placements: placements, analytics: analytics)

// AppleReceiptChecking пакет не реалізує — це StoreKit-логіка апки; передати свій конформер
// або nil, щоб покладатись тільки на Adapty.
let premium = PremiumService(adapty: adapty, apple: appOwnedReceiptChecker)
premium.start()

// 4. AppsFlyer — devKey/appId декодує й тримає апка, ніколи не пакет
let appsFlyer: AppsFlyerServicing = AppsFlyerService(analytics: analytics, adapty: adapty)
appsFlyer.configure(devKey: devKey, appId: appId, deviceId: deviceId)
```

Порядок виклику фіксований: **Firebase → Amplitude → Adapty → AppsFlyer**, `PremiumService.start()`
— одразу після Adapty. Чому саме такий порядок і повний `AppDelegate` — у довгому гайді.

`CrashReporting`, `AnalyticsTracking`, `AdaptyServicing`, `AppsFlyerServicing`,
`AppleReceiptChecking`, `PremiumStateStoring` — публічні протоколи, апка підмінює їх стабами
у UI-тестах.

## Що лишається на боці апки

- Ключі й ідентифікатори SDK, `GoogleService-Info.plist`, Run Script для dSYM, ключі в
  Info.plist, capabilities — усе, чого немає в коді пакета.
- Enum подій аналітики (`LogEventKey`), назви подій, місця виклику.
- Стаби сервісів для UI-тестів (`#if DEBUG` + `UITestMode.isActive` — рішення апки).
- Реалізація `AppleReceiptChecking` (StoreKit) і `AppleReceiptChecking`-конформер.
- Навігація за deep link'ом — пакет тільки логує й атрибутує, не веде юзера на екран.

## Структура

```
Sources/IntegrationKit/
├── Firebase/     Core + Crashlytics
├── Amplitude/    фасад аналітики, IDFA-плагін
├── Adapty/       активація, пейволи, профіль, покупки
├── AppsFlyer/    ATT, дип-лінки, атрибуція
├── Premium/      арбітраж преміуму над Adapty і рецептом
└── Support/      debugLog, деобфускація ключа
```

Тека на кожну інтеграцію, `Premium/` окремо — він не належить жодному SDK, а вирішує
між ними. SPM забирає файли рекурсивно, тому `Package.swift` про теки не знає.

## Збірка

Пакет сам по собі не збирається (`swift build` цілиться в macOS-хост). `BuildHost/` —
мінімальна iOS-апка на xcodegen, яка лінкує пакет:

```bash
cd BuildHost && xcb app-sim
```

## Перевірки

Дві self-перевірки без XCTest, пряма swift-компіляція й запуск:

```bash
./Checks/premium-resolver-check.sh          # PremiumResolver, 5 асертів
./Checks/appsflyer-attribution-check.sh     # AppsFlyerAttributionMapping, 4 асерти
```

## Статус

- [x] Крок 1 — каркас + Firebase
- [x] Крок 2 — Amplitude
- [x] Крок 3 — Adapty (+ `PremiumService` арбітраж)
- [x] Крок 4 — AppsFlyer
- [ ] Крок 5 — міграція апок на пакет (жодна апка ще не переведена)

Версія `0.1.0` — мінорна гілка ще може ламати API, поки пакет не обкатано на живій апці.

## Ліцензія

MIT © 2026 Yevhenii Petrenko — [LICENSE](LICENSE).
