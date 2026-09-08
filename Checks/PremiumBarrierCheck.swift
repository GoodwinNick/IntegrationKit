//
//  PremiumBarrierCheck.swift
//  IntegrationKit
//
//  PM-02 (the `refresh()` barrier) in four asserts — spec section 6, points 1-4.
//  Run:  ./Checks/premium-barrier-check.sh
//

import Adapty
import Foundation

/// Counts what the real `UserDefaultsPremiumStore` does: every write to `cached`, and a
/// notification only when the mirror flag actually changes value.
final class SpyStore: PremiumStateStoring {
	private let lock = NSLock()
	private var state: PremiumState?
	private var flag: Bool
	private var cachedWrites = 0
	private var notifications = 0

	init(cached: PremiumState? = nil, premium: Bool = false) {
		state = cached
		flag = premium
	}

	var writes: Int {
		lock.lock()
		defer { lock.unlock() }
		return cachedWrites
	}

	var notified: Int {
		lock.lock()
		defer { lock.unlock() }
		return notifications
	}

	var cached: PremiumState? {
		get {
			lock.lock()
			defer { lock.unlock() }
			return state
		}
		set {
			lock.lock()
			defer { lock.unlock() }
			cachedWrites += 1
			state = newValue
		}
	}

	var premium: Bool {
		get {
			lock.lock()
			defer { lock.unlock() }
			return flag
		}
		set {
			lock.lock()
			defer { lock.unlock() }
			guard flag != newValue else { return }
			flag = newValue
			notifications += 1
		}
	}
}

/// An Adapty that answers whatever it is told, after however long it is told.
final class FakeAdapty: AdaptyPremiumProviding {
	var premiumObserver: ((AdaptyProfile) -> Void)?
	var answer: AdaptyProfile?
	var delay: TimeInterval

	init(answer: AdaptyProfile?, delay: TimeInterval = 0) {
		self.answer = answer
		self.delay = delay
	}

	func profile() async -> AdaptyProfile? {
		if delay > 0 {
			try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
		}
		return answer
	}

	func products(placement: String) async -> [PremiumProduct] { [] }
	func buy(productId: String, placement: String) async -> PurchaseOutcome { .failed }
	func remoteValue<T>(placement: String, key: String) -> T? { nil }
	func logPaywallOpen(placement: String) {}
	func hasPaywall(placement: String) -> Bool { false }
}

/// The Apple side, same idea.
final class FakeApple: AppleSubscribing {
	var receipt: Bool?
	var delay: TimeInterval

	init(receipt: Bool?, delay: TimeInterval = 0) {
		self.receipt = receipt
		self.delay = delay
	}

	func checkReceipt() async -> Bool? {
		if delay > 0 {
			try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
		}
		return receipt
	}

	func restore() async -> RestoreOutcome { .notImplemented }
}

@main
enum PremiumBarrierCheck {
	static let hour: TimeInterval = 3600

	static func profile(active: Bool, expiresAt: Date? = nil) -> AdaptyProfile {
		AdaptyProfile(accessLevels: [
			"premium": AdaptyProfile.AccessLevel(id: "premium", isActive: active, isLifetime: false, expiresAt: expiresAt)
		])
	}

	/// Polls instead of awaiting: `refresh()` is fire-and-forget by contract, so the only thing
	/// an observer can do is watch the store.
	@discardableResult
	static func wait(_ seconds: TimeInterval = 2, for condition: () -> Bool) -> Bool {
		let deadline = Date().addingTimeInterval(seconds)
		while Date() < deadline {
			if condition() { return true }
			Thread.sleep(forTimeInterval: 0.005)
		}
		return condition()
	}

	static func main() {
		let now = Date()

		// 1. Both sources answer, the receipt first — exactly one store write and one
		//    notification, and the verdict is Adapty's. Two independent `apply`s would write
		//    twice: the receipt's intermediate value, then Adapty's overwrite.
		let store = SpyStore()
		let adapty = FakeAdapty(answer: profile(active: true, expiresAt: now + hour), delay: 0.15)
		let apple = FakeApple(receipt: true, delay: 0.01)
		let service = PremiumService(store: store, adapty: adapty, apple: apple, levels: ["premium"], sourceTimeout: 1)
		service.refresh()
		assert(wait { store.writes > 0 }, "case 1: the barrier must produce a verdict")
		// Long enough for a second, wrong write to show up if the barrier is not holding.
		Thread.sleep(forTimeInterval: 0.3)
		assert(store.writes == 1, "case 1: both sources answered — exactly one store write, got \(store.writes)")
		assert(store.notified == 1, "case 1: exactly one .premiumDidChange, got \(store.notified)")
		assert(store.cached?.source == .adapty, "case 1: Adapty decides when it answered")
		assert(store.cached?.isVerified == true && store.cached?.isPremium == true, "case 1: Adapty active means verified premium")

		// 2. Adapty stays silent, the receipt says yes — verdict by receipt, and no `awaiting`
		//    block is left behind: the next refresh still runs.
		let silentStore = SpyStore()
		let silentAdapty = FakeAdapty(answer: nil)
		let receiptApple = FakeApple(receipt: true)
		let silentService = PremiumService(store: silentStore, adapty: silentAdapty, apple: receiptApple, levels: ["premium"], sourceTimeout: 1)
		silentService.refresh()
		assert(wait { silentStore.cached?.isPremium == true }, "case 2: a silent Adapty must not stop the receipt verdict")
		assert(silentStore.cached?.source == .apple && silentStore.cached?.isVerified == false, "case 2: the receipt grants unverified premium")
		silentAdapty.answer = profile(active: false)
		silentService.refresh()
		assert(wait { silentStore.cached?.isPremium == false }, "case 2: a second refresh must run after Adapty went silent once")

		// 3. Nobody answers — nothing changes, and the next refresh still works. This is the
		//    exact scenario the two-flag version dead-locked on.
		let held = PremiumState(isPremium: true, source: .apple, isVerified: false)
		let mutedStore = SpyStore(cached: held, premium: true)
		let mutedAdapty = FakeAdapty(answer: nil)
		let mutedApple = FakeApple(receipt: nil)
		let mutedService = PremiumService(store: mutedStore, adapty: mutedAdapty, apple: mutedApple, levels: ["premium"], sourceTimeout: 1)
		mutedService.refresh()
		Thread.sleep(forTimeInterval: 0.2)
		assert(mutedStore.writes == 0, "case 3: nobody answered — nothing to write, got \(mutedStore.writes) writes")
		assert(mutedStore.notified == 0, "case 3: nobody answered — nothing to notify about")
		assert(mutedStore.cached == held, "case 3: the held state must survive a refresh nobody answered")
		mutedAdapty.answer = profile(active: true, expiresAt: now + hour)
		mutedService.refresh()
		assert(wait { mutedStore.cached?.isVerified == true }, "case 3: a refresh after both sources went silent must still work")

		// 4. The timeout fires — the verdict comes from whoever answered in time, and it comes
		//    on the timeout's schedule, not the stuck source's.
		let timeoutStore = SpyStore()
		let stuckAdapty = FakeAdapty(answer: profile(active: false), delay: 3)
		let quickApple = FakeApple(receipt: true, delay: 0.01)
		let timeoutService = PremiumService(store: timeoutStore, adapty: stuckAdapty, apple: quickApple, levels: ["premium"], sourceTimeout: 0.2)
		let started = Date()
		timeoutService.refresh()
		assert(wait(1.5) { timeoutStore.writes > 0 }, "case 4: a source that never answers must not hold the verdict")
		let elapsed = Date().timeIntervalSince(started)
		assert(elapsed < 1.5, "case 4: the verdict must arrive on the timeout, took \(elapsed)s")
		assert(timeoutStore.cached?.isPremium == true && timeoutStore.cached?.source == .apple, "case 4: the verdict is built from what did arrive")

		print("PremiumService barrier: 4/4 OK")
	}
}
