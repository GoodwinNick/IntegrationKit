//
//  PremiumLevelsCheck.swift
//  IntegrationKit
//
//  PM-10 and TM-10 — access per level (0.11.0, couples-games). Written red first from the approved
//  schemas: `hasAccess(level:)`, the product → level map, the per-level verdicts and `-grantLevel` did
//  not exist, so the file did not compile. Row numbers in the messages are the rows of
//  «PM-10 Ризики» and «TM-10 Ризики».
//  Run:  ./Checks/premium-levels-check.sh
//

import Adapty
import Foundation

/// An Adapty that answers whatever profile it is told, after however long it is told.
final class LevelAdapty: AdaptyPremiumProviding {
	var premiumObserver: ((AdaptyProfile, Bool) -> Void)?
	var answer: AdaptyProfile?
	var delay: TimeInterval
	var buyResult: PurchaseVerdict = .failed

	init(answer: AdaptyProfile?, delay: TimeInterval = 0) {
		self.answer = answer
		self.delay = delay
	}

	var isActive: Bool { true }

	func profile() async -> AdaptyProfile? {
		if delay > 0 {
			try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
		}
		return answer
	}

	func products(placement: String) async -> AdaptyProductsAnswer { .notReady }
	func buy(productId: String, placement: String) async -> PurchaseVerdict { buyResult }
	func remoteValue<T>(placement: String, key: String) -> RemoteValue<T> { .notReady }
	func logPaywallOpen(placement: String) {}
	func hasPaywall(placement: String) -> Bool { false }
	func paywallState(placement: String) -> PaywallState { .unavailable }
	func syncReceipt() {}
	func setProfileValue(value: String, key: String) {}
}

/// The Apple side with an answer PER PRODUCT, folded the way `StoreKitService` folds
/// `Transaction.currentEntitlements`: `owned` maps a product to its expiry, `nil` meaning a
/// non-consumable. `checked == false` is a receipt that could not be read at all.
final class LevelApple: AppleSubscribing {
	var owned: [String: Date?]
	var checked: Bool
	var restoreResult: RestoreOutcome = .nothingToRestore
	var purchaseResult: PurchaseOutcome = .failed
	/// What `restore()` puts into `owned` — the store handing back what the account bought.
	var restoredOwned: [String: Date?]?
	private let lock = NSLock()
	private var levelAskCount = 0

	init(owned: [String: Date?] = [:], checked: Bool = true) {
		self.owned = owned
		self.checked = checked
	}

	/// How many per-product receipt questions were asked. Zero in an app without a map (PM-10 row 11).
	var levelAsks: Int {
		lock.lock()
		defer { lock.unlock() }
		return levelAskCount
	}

	private func countLevelAsk() {
		lock.lock()
		levelAskCount += 1
		lock.unlock()
	}

	func checkReceipt() async -> ReceiptAnswer? {
		fold(Set(owned.keys))
	}

	func checkReceipt(productIds: Set<String>) async -> ReceiptAnswer? {
		countLevelAsk()
		return fold(productIds)
	}

	private func fold(_ ids: Set<String>) -> ReceiptAnswer? {
		guard checked else { return nil }
		var isActive = false
		var latest: Date?
		for (id, expiry) in owned where ids.contains(id) {
			guard let expiry else {
				isActive = true
				continue
			}
			latest = max(latest ?? .distantPast, expiry)
			if expiry > Date() {
				isActive = true
			}
		}
		return ReceiptAnswer(isActive: isActive, expiresAt: latest)
	}

	func restore() async -> RestoreOutcome {
		if let restoredOwned {
			owned = restoredOwned
		}
		return restoreResult
	}

	func purchase(productId: String) async -> PurchaseOutcome { purchaseResult }
	func products(ids: Set<String>) async -> [String: PremiumProduct] { [:] }
}

/// An app's own fake written against 0.10.0: every member it had to implement then, and not one more.
/// It compiling at all is PM-10 row 27 — the new member comes with a default.
final class OldAppFake: PremiumServicing {
	var isPremium: Bool
	init(isPremium: Bool) { self.isPremium = isPremium }
	func start() {}
	func refresh() {}
	func restore(completion: @escaping (RestoreOutcome) -> Void) {}
	func purchase(_ productId: String, placement: String, completion: @escaping (PurchaseOutcome) -> Void) {}
	func activeSubscriptionIds(completion: @escaping (Set<String>?) -> Void) {}
	func product(_ productId: String, placement: String, completion: @escaping (PremiumProduct?) -> Void) {}
	func products(placement: String, completion: @escaping ([PremiumProduct]) -> Void) {}
	func hasPaywall(placement: String) -> Bool { false }
	func paywallState(placement: String) -> PaywallState { .unavailable }
	func remoteValue<T>(placement: String, key: String) -> RemoteValue<T> { .notReady }
	func logPaywallOpen(placement: String) {}
	var configurationIssues: [String] { [] }
}

@main
enum PremiumLevelsCheck {
	static let hour: TimeInterval = 3600
	static let levels: Set<String> = ["lifetime", "remote_play"]
	static let map = ["cg.lifetime": "lifetime", "rp.month": "remote_play", "rp.year": "remote_play"]
	static let productIds: Set<String> = ["cg.lifetime", "rp.month", "rp.year"]

	/// A profile with the given levels; a level with no date and `lifetime: true` is a lifetime one.
	static func profile(_ entries: [(id: String, active: Bool, expiresAt: Date?)]) -> AdaptyProfile {
		AdaptyProfile(accessLevels: Dictionary(uniqueKeysWithValues: entries.map {
			($0.id, AdaptyProfile.AccessLevel(id: $0.id, isActive: $0.active, isLifetime: $0.expiresAt == nil, expiresAt: $0.expiresAt))
		}))
	}

	static func suite() -> UserDefaults {
		UserDefaults(suiteName: "premium-levels-check-\(UUID().uuidString)")!
	}

	/// The real store on a throwaway suite — the notification rows need the real setter.
	static func service(
		adapty: LevelAdapty?,
		apple: LevelApple?,
		defaults: UserDefaults,
		levels: Set<String> = PremiumLevelsCheck.levels,
		productLevels: [String: String] = PremiumLevelsCheck.map,
		productIds: Set<String> = PremiumLevelsCheck.productIds
	) -> PremiumService {
		PremiumService(
			store: UserDefaultsPremiumStore(defaults: defaults),
			adapty: adapty,
			apple: apple,
			levels: levels,
			sourceTimeout: 1,
			waitingTimeout: 0.3,
			productIds: productIds,
			productLevels: productLevels,
			priceCache: PriceCache(defaults: suite())
		)
	}

	@discardableResult
	static func eventually(_ condition: () -> Bool, within seconds: TimeInterval = 3) -> Bool {
		let deadline = Date().addingTimeInterval(seconds)
		while Date() < deadline {
			if condition() { return true }
			RunLoop.current.run(until: Date().addingTimeInterval(0.005))
		}
		return condition()
	}

	static func pump(_ seconds: TimeInterval) {
		RunLoop.current.run(until: Date().addingTimeInterval(seconds))
	}

	/// Counts `.premiumDidChange` while `body` runs and the main queue drains after it. Every row before
	/// has settled by then, so what lands here is this row's.
	static func notifications(during body: () -> Void, settle: TimeInterval = 0.6) -> Int {
		pump(0.3)
		var count = 0
		let token = NotificationCenter.default.addObserver(forName: .premiumDidChange, object: nil, queue: nil) { _ in count += 1 }
		body()
		pump(settle)
		NotificationCenter.default.removeObserver(token)
		return count
	}

	static func main() {
		setvbuf(stdout, nil, _IONBF, 0)
		let now = Date()
		var passed = 0
		func row() { passed += 1 }

		// MARK: PM-10

		// 1. Row 1: Adapty grants remote_play only — the levels do not leak into each other.
		let onlyRemote = service(adapty: LevelAdapty(answer: profile([("remote_play", true, now + hour)])), apple: LevelApple(), defaults: suite())
		onlyRemote.start()
		assert(eventually { onlyRemote.hasAccess(level: "remote_play") }, "PM-10 row 1: a remote_play grant must open remote_play")
		pump(0.2)
		assert(onlyRemote.hasAccess(level: "lifetime") == false, "PM-10 row 1: a remote_play grant must not open lifetime")
		assert(onlyRemote.isPremium, "PM-10 row 1: isPremium stays «any access at all»")
		row()

		// 2. Row 2: every level keeps its own date. Lifetime has none, and it must not hide remote_play's;
		//    a remote_play that ended does not borrow lifetime's open state either.
		let datesDefaults = suite()
		let dates = service(adapty: LevelAdapty(answer: profile([("remote_play", true, now + hour), ("lifetime", true, nil)])), apple: LevelApple(), defaults: datesDefaults)
		dates.start()
		assert(eventually { dates.hasAccess(level: "remote_play") && dates.hasAccess(level: "lifetime") }, "PM-10 row 2: both granted levels must open")
		let datesStore = UserDefaultsPremiumStore(defaults: datesDefaults)
		assert(datesStore.levels["remote_play"]?.expiresAt.map { abs($0.timeIntervalSince(now + hour)) < 1 } == true, "PM-10 row 2: remote_play keeps its own date, got \(String(describing: datesStore.levels["remote_play"]))")
		assert(datesStore.levels["lifetime"]?.expiresAt == nil, "PM-10 row 2: lifetime has no date, got \(String(describing: datesStore.levels["lifetime"]))")
		let ended = service(adapty: LevelAdapty(answer: profile([("remote_play", false, now - hour), ("lifetime", true, nil)])), apple: LevelApple(), defaults: suite())
		ended.start()
		assert(eventually { ended.hasAccess(level: "lifetime") }, "PM-10 row 2: lifetime must open")
		pump(0.2)
		assert(ended.hasAccess(level: "remote_play") == false, "PM-10 row 2: an ended remote_play stays closed next to a live lifetime")
		row()

		// 3. Rows 3 and 22: a purchase through Adapty while Adapty is too slow for the barrier — the mark
		//    opens the level of the product bought, and only that one, before the completion runs.
		let buyAdapty = LevelAdapty(answer: profile([]), delay: 1.5)
		buyAdapty.buyResult = .success
		let bought = service(adapty: buyAdapty, apple: LevelApple(), defaults: suite())
		bought.start()
		var boughtSeen: (remote: Bool, lifetime: Bool, outcome: PurchaseOutcome)?
		bought.purchase("rp.month", placement: "main") { outcome in
			boughtSeen = (bought.hasAccess(level: "remote_play"), bought.hasAccess(level: "lifetime"), outcome)
		}
		assert(eventually { boughtSeen != nil }, "PM-10 row 3: the purchase must settle")
		assert(boughtSeen?.outcome == .purchased, "PM-10 row 3: expected .purchased, got \(String(describing: boughtSeen?.outcome))")
		assert(boughtSeen?.remote == true, "PM-10 rows 3, 22: remote_play must already be open inside the completion")
		assert(boughtSeen?.lifetime == false, "PM-10 row 3: buying remote_play must not open lifetime")
		row()

		// 4. Row 4: the StoreKit fallback marks by the same map.
		let fallbackAdapty = LevelAdapty(answer: profile([]), delay: 1.5)
		fallbackAdapty.buyResult = .retryWithStoreKit
		let fallbackApple = LevelApple()
		fallbackApple.purchaseResult = .purchased
		let fallback = service(adapty: fallbackAdapty, apple: fallbackApple, defaults: suite())
		fallback.start()
		var fallbackSeen: (remote: Bool, lifetime: Bool)?
		fallback.purchase("cg.lifetime", placement: "main") { _ in
			fallbackSeen = (fallback.hasAccess(level: "remote_play"), fallback.hasAccess(level: "lifetime"))
		}
		assert(eventually { fallbackSeen != nil }, "PM-10 row 4: the fallback purchase must settle")
		assert(fallbackSeen?.lifetime == true, "PM-10 row 4: the StoreKit fallback must open the bought product's level")
		assert(fallbackSeen?.remote == false, "PM-10 row 4: and nothing else")
		row()

		// 5. Rows 5 and 25: the receipt per level. A lifetime purchase on the device opens lifetime and not
		//    remote_play, with Adapty silent.
		let receiptOnly = service(adapty: LevelAdapty(answer: nil), apple: LevelApple(owned: ["cg.lifetime": nil]), defaults: suite())
		receiptOnly.start()
		assert(eventually { receiptOnly.hasAccess(level: "lifetime") }, "PM-10 row 5: the lifetime product in the receipt must open lifetime")
		pump(0.2)
		assert(receiptOnly.hasAccess(level: "remote_play") == false, "PM-10 row 5: a lifetime product must not open remote_play")
		let subscriptionOnly = service(adapty: LevelAdapty(answer: nil), apple: LevelApple(owned: ["rp.year": now + hour]), defaults: suite())
		subscriptionOnly.start()
		assert(eventually { subscriptionOnly.hasAccess(level: "remote_play") }, "PM-10 row 5: a subscription in the receipt must open remote_play")
		pump(0.2)
		assert(subscriptionOnly.hasAccess(level: "lifetime") == false, "PM-10 row 5: a subscription must not open lifetime")
		row()

		// 6. Row 6: a restore opens the levels whose products the store gave back, and leaves the rest.
		let restoreApple = LevelApple()
		restoreApple.restoreResult = .restored
		restoreApple.restoredOwned = ["cg.lifetime": nil]
		let restored = service(adapty: LevelAdapty(answer: nil), apple: restoreApple, defaults: suite())
		restored.start()
		pump(0.2)
		var restoreSeen: (remote: Bool, lifetime: Bool)?
		restored.restore { _ in restoreSeen = (restored.hasAccess(level: "remote_play"), restored.hasAccess(level: "lifetime")) }
		assert(eventually { restoreSeen != nil }, "PM-10 row 6: the restore must settle")
		assert(restoreSeen?.lifetime == true, "PM-10 row 6: the restored lifetime must open")
		assert(restoreSeen?.remote == false, "PM-10 row 6: remote_play was not restored and must stay closed")
		row()

		// 7. Rows 7-9: the three map mistakes, each one line in configurationIssues at construction.
		ConfigurationIssues.shared.reset()
		_ = service(
			adapty: LevelAdapty(answer: nil), apple: LevelApple(), defaults: suite(),
			productLevels: ["cg.lifetime": "lifetime", "rp.month": "remote_play", "rp.year": "remote_play", "bonus.pack": "ghost", "rp.week": "remote_play"],
			productIds: ["cg.lifetime", "rp.month", "rp.year", "bonus.pack", "orphan"]
		)
		let mapIssues = ConfigurationIssues.shared.all
		assert(mapIssues.contains { $0.contains("ghost") }, "PM-10 row 8: a map level missing from levels must be named, got \(mapIssues)")
		assert(mapIssues.contains { $0.contains("orphan") }, "PM-10 row 7: a product with no level must be named, got \(mapIssues)")
		assert(mapIssues.contains { $0.contains("rp.week") }, "PM-10 row 9: a map product missing from productIds must be named, got \(mapIssues)")
		assert(mapIssues.count == 3, "PM-10 rows 7-9: one line per mistake, got \(mapIssues)")
		// Row 7, the purchase half: a product without a level opens no level (the old verdict still turns on).
		let orphanAdapty = LevelAdapty(answer: nil)
		orphanAdapty.buyResult = .success
		let orphan = service(adapty: orphanAdapty, apple: LevelApple(), defaults: suite(), productIds: productIds.union(["orphan"]))
		orphan.start()
		var orphanDone = false
		orphan.purchase("orphan", placement: "main") { _ in orphanDone = true }
		assert(eventually { orphanDone }, "PM-10 row 7: the purchase must settle")
		assert(!orphan.hasAccess(level: "lifetime") && !orphan.hasAccess(level: "remote_play"), "PM-10 row 7: a product with no level must open no level")
		assert(orphan.isPremium, "PM-10 row 7: isPremium is as in 0.10.0 — the local purchase turns it on")
		row()

		// 8. Row 10: a level the app never configured — false, and one line however often it is asked.
		ConfigurationIssues.shared.reset()
		let typo = service(adapty: LevelAdapty(answer: profile([("remote_play", true, now + hour)])), apple: LevelApple(), defaults: suite())
		typo.start()
		eventually { typo.hasAccess(level: "remote_play") }
		assert(typo.hasAccess(level: "remote_ply") == false, "PM-10 row 10: an unknown level is closed")
		_ = typo.hasAccess(level: "remote_ply")
		let typoIssues = ConfigurationIssues.shared.all.filter { $0.contains("remote_ply") }
		assert(typoIssues.count == 1, "PM-10 row 10: exactly one line for the unknown level, got \(ConfigurationIssues.shared.all)")
		row()

		// 9. Row 11: no map — exactly 0.10.0. hasAccess mirrors isPremium for a configured level, nothing new
		//    is written, the receipt is never asked per product, and the notification count is the old one.
		let plainDefaults = suite()
		let plainApple = LevelApple()
		let plainAdapty = LevelAdapty(answer: profile([("premium", true, now + hour)]))
		let plain = service(adapty: plainAdapty, apple: plainApple, defaults: plainDefaults, levels: ["premium"], productLevels: [:], productIds: ["sub.month"])
		let plainNotified = notifications(during: {
			plain.start()
			eventually { plain.isPremium }
		})
		assert(plain.hasAccess(level: "premium") == true && plain.isPremium, "PM-10 row 11: without a map hasAccess is isPremium")
		assert(plainNotified == 1, "PM-10 row 11: one .premiumDidChange as in 0.10.0, got \(plainNotified)")
		assert(plainDefaults.object(forKey: "premiumLevelsKey") == nil, "PM-10 row 11: no new key on disk without a map")
		assert(plainApple.levelAsks == 0, "PM-10 row 11: no per-product receipt question without a map, got \(plainApple.levelAsks)")
		let plainFree = service(adapty: LevelAdapty(answer: profile([])), apple: LevelApple(), defaults: suite(), levels: ["premium"], productLevels: [:], productIds: ["sub.month"])
		plainFree.start()
		pump(0.3)
		assert(plainFree.hasAccess(level: "premium") == false && plainFree.isPremium == false, "PM-10 row 11: free stays free through hasAccess too")
		row()

		// 10. Row 12: a denial for a level is not an answer — a cached open level stays open on it.
		let heldDefaults = suite()
		UserDefaultsPremiumStore(defaults: heldDefaults).levels = ["remote_play": PremiumState(isPremium: true, source: .adapty, isVerified: true, expiresAt: now + hour)]
		let held = service(adapty: LevelAdapty(answer: profile([("remote_play", false, nil)])), apple: LevelApple(checked: false), defaults: heldDefaults)
		held.start()
		pump(0.4)
		assert(held.hasAccess(level: "remote_play"), "PM-10 row 12: an Adapty denial must not close a held level")
		row()

		// 11. Row 14: a restart with nobody answering — the levels come back from disk at once.
		let restartDefaults = suite()
		let first = service(adapty: LevelAdapty(answer: profile([("remote_play", true, now + hour)])), apple: LevelApple(), defaults: restartDefaults)
		first.start()
		assert(eventually { first.hasAccess(level: "remote_play") }, "PM-10 row 14: the first launch must open remote_play")
		let second = service(adapty: LevelAdapty(answer: nil), apple: LevelApple(checked: false), defaults: restartDefaults)
		second.start()
		assert(second.hasAccess(level: "remote_play"), "PM-10 row 14: offline, the level must be read from disk right after start")
		assert(second.hasAccess(level: "lifetime") == false, "PM-10 row 14: and the closed one stays closed")
		row()

		// 12. Row 15: the first launch with a map — an old dateless «yes» is not copied into the levels.
		let upgradeDefaults = suite()
		UserDefaultsPremiumStore(defaults: upgradeDefaults).cached = PremiumState(isPremium: true, source: .adapty, isVerified: true, expiresAt: nil)
		let upgraded = service(adapty: LevelAdapty(answer: nil), apple: LevelApple(), defaults: upgradeDefaults)
		upgraded.start()
		pump(0.4)
		assert(upgraded.isPremium, "PM-10 row 15: the old verdict stays as it was")
		assert(!upgraded.hasAccess(level: "lifetime") && !upgraded.hasAccess(level: "remote_play"), "PM-10 row 15: the levels start from nothing")
		row()

		// 13. Row 16: a corrupted level payload reads as «no levels» and does not take the old verdict down.
		let corruptDefaults = suite()
		UserDefaultsPremiumStore(defaults: corruptDefaults).cached = PremiumState(isPremium: true, source: .apple, isVerified: false, expiresAt: now + hour)
		corruptDefaults.set(Data("{ not levels".utf8), forKey: "premiumLevelsKey")
		assert(UserDefaultsPremiumStore(defaults: corruptDefaults).levels.isEmpty, "PM-10 row 16: an unreadable payload is no levels")
		let corrupt = service(adapty: LevelAdapty(answer: nil), apple: LevelApple(checked: false), defaults: corruptDefaults)
		corrupt.start()
		assert(corrupt.isPremium, "PM-10 row 16: the old verdict must survive a broken level payload")
		assert(!corrupt.hasAccess(level: "lifetime"), "PM-10 row 16: and the levels are closed")
		row()

		// 14. Rows 18, 20, 23: one level changes while isPremium stays true — exactly one notification; the
		//     same push again — none.
		let pushDefaults = suite()
		let pushAdapty = LevelAdapty(answer: nil)
		let pushed = service(adapty: pushAdapty, apple: LevelApple(checked: false), defaults: pushDefaults)
		UserDefaultsPremiumStore(defaults: pushDefaults).levels = ["lifetime": PremiumState(isPremium: true, source: .apple, isVerified: false)]
		UserDefaultsPremiumStore(defaults: pushDefaults).cached = PremiumState(isPremium: true, source: .apple, isVerified: false)
		UserDefaultsPremiumStore(defaults: pushDefaults).premium = true
		pushed.start()
		pump(0.4)
		let both = profile([("lifetime", true, nil), ("remote_play", true, now + hour)])
		let levelOnly = notifications(during: { pushAdapty.premiumObserver?(both, true) })
		assert(pushed.hasAccess(level: "remote_play"), "PM-10 row 23: the push must open remote_play")
		assert(levelOnly == 1, "PM-10 row 18: a level change with isPremium unchanged posts exactly one, got \(levelOnly)")
		let repeated = notifications(during: { pushAdapty.premiumObserver?(both, true) })
		assert(repeated == 0, "PM-10 row 20: nothing changed — no notification, got \(repeated)")
		row()

		// 15. Row 19: isPremium and a level change in the same update — still exactly one.
		let jointAdapty = LevelAdapty(answer: nil)
		let joint = service(adapty: jointAdapty, apple: LevelApple(checked: false), defaults: suite())
		joint.start()
		pump(0.4)
		let jointCount = notifications(during: { jointAdapty.premiumObserver?(profile([("remote_play", true, now + hour)]), true) })
		assert(joint.isPremium && joint.hasAccess(level: "remote_play"), "PM-10 row 19: both must be open after the push")
		assert(jointCount == 1, "PM-10 row 19: two changes, one notification, got \(jointCount)")
		row()

		// 16. Row 21: a refresh that set out before a push and lands after it does not take the level back.
		let raceAdapty = LevelAdapty(answer: profile([("lifetime", true, nil)]), delay: 0.4)
		let race = service(adapty: raceAdapty, apple: LevelApple(checked: false), defaults: suite())
		race.start()
		pump(0.6)
		race.refresh()
		pump(0.05)
		raceAdapty.premiumObserver?(profile([("lifetime", true, nil), ("remote_play", true, now + hour)]), true)
		pump(0.8)
		assert(race.hasAccess(level: "remote_play"), "PM-10 row 21: the older refresh must not close what the newer push opened")
		row()

		// 17. Row 24: a transaction from the queue carries no product — no level gets a mark.
		let queued = service(adapty: LevelAdapty(answer: nil), apple: LevelApple(), defaults: suite())
		queued.start()
		pump(0.2)
		queued.purchaseDelivered()
		pump(0.5)
		assert(queued.isPremium, "PM-10 row 24: the old verdict takes the mark as in 0.10.0")
		assert(!queued.hasAccess(level: "lifetime") && !queued.hasAccess(level: "remote_play"), "PM-10 row 24: no level is marked by a queued transaction")
		row()

		// 18. Row 25: a level with no product (handed out from the dashboard) opens through Adapty alone.
		let promo = service(
			adapty: LevelAdapty(answer: profile([("bonus", true, now + hour)])), apple: LevelApple(), defaults: suite(),
			levels: levels.union(["bonus"])
		)
		promo.start()
		assert(eventually { promo.hasAccess(level: "bonus") }, "PM-10 row 25: a dashboard-only level must open through Adapty")
		assert(!promo.hasAccess(level: "remote_play"), "PM-10 row 25: and nothing else")
		row()

		// 19. Row 27: an app fake written against 0.10.0 still compiles, and its hasAccess is its isPremium.
		assert(OldAppFake(isPremium: true).hasAccess(level: "anything"), "PM-10 row 27: the default must answer isPremium (true)")
		assert(!OldAppFake(isPremium: false).hasAccess(level: "anything"), "PM-10 row 27: the default must answer isPremium (false)")
		row()

		// MARK: TM-10

		// 20. Rows 1-3: the flag accumulates, folds a duplicate, and a missing value eats nothing.
		let accumulated = TestModeFlagParser.parse(["-grantLevel", "a", "-grantLevel", "b", "-grantLevel", "a"])
		assert(accumulated.grantLevels == ["a", "b"], "TM-10 row 1: expected {a, b}, got \(accumulated.grantLevels)")
		assert(accumulated.issues.isEmpty, "TM-10 row 1: a well-formed flag leaves no issue, got \(accumulated.issues)")
		assert(TestModeFlagParser.allNames.contains("-grantLevel"), "TM-10 row 2: the name must be one of the package's own")
		let eaten = TestModeFlagParser.parse(["-grantLevel", "-premium"])
		assert(eaten.grantLevels.isEmpty && eaten.adapty == .grant, "TM-10 row 3: -premium must survive, got \(eaten.grantLevels) / \(eaten.adapty)")
		assert(eaten.issues.count == 1 && eaten.issues[0].contains("-grantLevel"), "TM-10 row 3: one line naming the flag, got \(eaten.issues)")
		row()

		/// The levels active in what the fake source answers for `arguments`.
		func grantedLevels(_ arguments: [String]) -> Set<String>? {
			let source = FakeAdaptySource(flags: TestModeFlagParser.parse(arguments), levels: levels, productIds: [], sink: nil)
			var answer: AdaptyProfile??
			Task { answer = .some(await source.profile()) }
			guard eventually({ answer != nil }), let profile = answer ?? nil else { return nil }
			return Set(profile.accessLevels.values.filter(\.isActive).map(\.id))
		}

		// 21. Rows 4, 5, 7, 8: what the grant carries.
		ConfigurationIssues.shared.reset()
		assert(grantedLevels(["-premium", "-grantLevel", "lifetime", "-grantLevel", "remote_play"]) == ["lifetime", "remote_play"], "TM-10 row 4: both levels must decode in one profile")
		assert(ConfigurationIssues.shared.all.isEmpty, "TM-10 row 4: a profile that decodes records nothing, got \(ConfigurationIssues.shared.all)")
		assert(grantedLevels(["-premium", "-grantLevel", "remote_play", "-adaptyLevelId", "lifetime"]) == ["lifetime", "remote_play"], "TM-10 row 7: -grantLevel and -adaptyLevelId add up")
		assert(grantedLevels(["-premium"]) == ["lifetime"], "TM-10 row 8: without -grantLevel the grant is the app's first level, as before")
		assert(grantedLevels(["-premium", "-adaptyLevelId", "remote_play"]) == ["remote_play"], "TM-10 row 8: -adaptyLevelId alone, as before")
		assert(grantedLevels(["-noPremium", "-grantLevel", "remote_play"]) == [], "TM-10 row 5: a denial carries no level")
		assert(grantedLevels(["-adaptySilent", "-premium", "-grantLevel", "remote_play"]) == nil, "TM-10: silence is stronger than the levels")
		row()

		// 22. Row 6: the deferred grant brings the same levels; the deferred removal none.
		let grantPush = FakeAdaptySource(flags: TestModeFlagParser.parse(["-adaptySilent", "-premiumAfter", "0.2", "-grantLevel", "lifetime", "-grantLevel", "remote_play"]), levels: levels, productIds: [], sink: nil)
		var grantPushed: AdaptyProfile?
		grantPush.premiumObserver = { profile, _ in grantPushed = profile }
		assert(eventually({ grantPushed != nil }), "TM-10 row 6: the deferred grant must arrive")
		assert(Set(grantPushed?.accessLevels.values.filter(\.isActive).map(\.id) ?? []) == ["lifetime", "remote_play"], "TM-10 row 6: the push must carry both levels, got \(String(describing: grantPushed?.accessLevels.keys))")
		let revokePush = FakeAdaptySource(flags: TestModeFlagParser.parse(["-premium", "-noPremiumAfter", "0.2", "-grantLevel", "remote_play"]), levels: levels, productIds: [], sink: nil)
		var revokePushed: AdaptyProfile?
		revokePush.premiumObserver = { profile, _ in revokePushed = profile }
		assert(eventually({ revokePushed != nil }), "TM-10 row 6: the deferred removal must arrive")
		assert(revokePushed?.accessLevels.values.contains(where: \.isActive) == false, "TM-10 row 6: the removal carries no level")
		row()

		/// The whole premium layer on the fake sources, as the composition root builds it in a test run.
		func testLayer(_ arguments: [String]) -> PremiumService {
			let flags = TestModeFlagParser.parse(arguments)
			return PremiumService(
				store: UserDefaultsPremiumStore(defaults: suite()),
				adapty: FakeAdaptySource(flags: flags, levels: levels, productIds: productIds, sink: nil),
				apple: FakeAppleStore(flags: flags, productIds: productIds),
				levels: levels,
				productIds: productIds,
				productLevels: map,
				priceCache: PriceCache(defaults: suite())
			)
		}

		// 23. «Результат для PM-10»: the table, through the real arbiter.
		let table: [(arguments: [String], lifetime: Bool, remote: Bool, premium: Bool)] = [
			(["-premium", "-grantLevel", "lifetime"], true, false, true),
			(["-premium", "-grantLevel", "remote_play"], false, true, true),
			(["-premium", "-grantLevel", "lifetime", "-grantLevel", "remote_play"], true, true, true),
			(["-premium"], true, false, true),
			(["-noPremium"], false, false, false),
			([], false, false, false),
			(["-adaptySilent"], false, false, false),
		]
		for entry in table {
			let layer = testLayer(entry.arguments + ["-receiptDelay", "0"])
			layer.start()
			pump(0.4)
			assert(layer.hasAccess(level: "lifetime") == entry.lifetime, "TM-10 table \(entry.arguments): lifetime expected \(entry.lifetime)")
			assert(layer.hasAccess(level: "remote_play") == entry.remote, "TM-10 table \(entry.arguments): remote_play expected \(entry.remote)")
			assert(layer.isPremium == entry.premium, "TM-10 table \(entry.arguments): isPremium expected \(entry.premium)")
		}
		let paying = testLayer(["-noPremium", "-receiptDelay", "0", "-storePurchaseDelay", "0"])
		paying.start()
		var payingSeen: (remote: Bool, lifetime: Bool)?
		paying.purchase("rp.month", placement: "main") { _ in payingSeen = (paying.hasAccess(level: "remote_play"), paying.hasAccess(level: "lifetime")) }
		assert(eventually({ payingSeen != nil }), "TM-10 table: the test purchase must settle")
		assert(payingSeen?.remote == true && payingSeen?.lifetime == false, "TM-10 table: a test purchase of rp.month opens remote_play only, got \(String(describing: payingSeen))")
		row()

		// 24. Row 9: -noPremiumCache wipes the level verdicts too, before anything reads them. The graph
		//     works on `.standard`, so the row cleans up after itself.
		let standard = UserDefaults.standard
		UserDefaultsPremiumStore().levels = ["remote_play": PremiumState(isPremium: true, source: .adapty, isVerified: true)]
		let graph = TestModeGraph.make(arguments: ["-noPremiumCache"], environment: [:], levels: levels, productIds: productIds, remoteConfigDefaults: [:])
		assert(graph.store.levels.isEmpty, "TM-10 row 9: -noPremiumCache must wipe the level verdicts, got \(graph.store.levels)")
		for key in ["premiumStateKey", "premiumKey", "premiumLevelsKey", "priceCacheKey", TestModeGraph.runMarkKey] {
			standard.removeObject(forKey: key)
		}
		row()

		// 25. Row 10: the live launch after a test run wipes the level verdicts, and says so.
		ConfigurationIssues.shared.reset()
		let leftovers = suite()
		leftovers.set(true, forKey: TestModeGraph.runMarkKey)
		leftovers.set(Data("{}".utf8), forKey: "premiumLevelsKey")
		TestModeGraph.wipeTestRunLeftovers(defaults: leftovers)
		assert(leftovers.object(forKey: "premiumLevelsKey") == nil, "TM-10 row 10: the level verdicts must be wiped")
		assert(ConfigurationIssues.shared.all.first?.contains("premiumLevelsKey") == true, "TM-10 row 10: the line must name the key, got \(ConfigurationIssues.shared.all)")
		row()

		// 26. PM-10 rows 13 and 26: a product the map ties to lifetime unlocks remote_play in the dashboard.
		//     Adapty still opens remote_play, nothing closes, and the log says so; every update logs each
		//     level with its source.
		let traceLock = NSLock()
		var traceLines: [String] = []
		debugLogSink = { line in traceLock.lock(); traceLines.append(line); traceLock.unlock() }
		let mismatchAdapty = LevelAdapty(answer: AdaptyProfile(accessLevels: [
			"remote_play": .init(id: "remote_play", isActive: true, isLifetime: false, expiresAt: now + hour, vendorProductId: "cg.lifetime"),
		]))
		let mismatch = service(adapty: mismatchAdapty, apple: LevelApple(), defaults: suite())
		mismatch.start()
		assert(eventually { mismatch.hasAccess(level: "remote_play") }, "PM-10 row 13: Adapty must still open its own level")
		pump(0.2)
		debugLogSink = nil
		traceLock.lock()
		let traced = traceLines.filter { $0.hasPrefix("[IntegrationKit][PremiumService] ") }
		traceLock.unlock()
		assert(!mismatch.hasAccess(level: "lifetime"), "PM-10 row 13: the map's level is not opened by Adapty's answer")
		assert(traced.contains { $0.contains("\"remote_play\"") && $0.contains("cg.lifetime") && $0.contains("\"lifetime\"") }, "PM-10 row 13: one info line naming the level, the product and the map's level, got \(traced)")
		assert(traced.contains { $0.contains("lifetime closed (none)") && $0.contains("remote_play open (adapty)") }, "PM-10 row 26: the update line must carry every level and its source, got \(traced)")
		row()

		print("PremiumLevels: \(passed)/26 OK")
	}
}
