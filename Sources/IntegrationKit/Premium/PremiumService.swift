//
//  PremiumService.swift
//  IntegrationKit
//
//  Single source of truth for premium access. Adapty decides, Apple's receipt is the
//  reserve, the cache covers the offline launch. Nothing else writes the premium flag.
//

import Adapty
import Foundation

public final class PremiumService: PremiumServicing {
	private let store: PremiumStateStoring
	private let adapty: AdaptyPremiumProviding?
	private let apple: AppleSubscribing?
	/// Access level ids as named in the Adapty dashboard — the app decides, not the library.
	private let levels: Set<String>
	// Guards the cached state AND its flag mirror together — see `apply`.
	// Holding it across the mirror write is safe: the store's setter posts `.premiumDidChange`
	// on `DispatchQueue.main.async`, so no observer ever runs inside this critical section.
	// Recursive anyway, so that a future synchronous notification cannot turn into a self-deadlock.
	private let lock = NSRecursiveLock()
	// PM-02 row 3: one refresh at a time. Each flag says that the running refresh is still waiting
	// on that source; while either is set, a second `refresh()` is a no-op instead of a second pair
	// of requests. Both are cleared once both answers arrived.
	// Ceiling: an Adapty that never answers leaves `awaitingAdapty` set and blocks later refreshes.
	// That is PM-02 row 4 (no timeout on `refreshPremium`), a separate fix.
	private var awaitingAdapty = false
	private var awaitingApple = false

	public init(
		store: PremiumStateStoring = UserDefaultsPremiumStore(),
		adapty: AdaptyPremiumProviding? = nil,
		apple: AppleSubscribing? = nil,
		levels: Set<String> = ["premium"]
	) {
		self.store = store
		self.adapty = adapty
		self.apple = apple
		self.levels = levels
	}

	/// Convenience read for call sites that just need the current answer.
	public var isPremium: Bool {
		store.cached?.isPremium ?? false
	}

	/// PM-01: seeds the cache on the first launch after the update, then publishes what we know.
	public func start() {
		lock.lock()
		if store.cached == nil {
			let wasPremium = store.premium
			store.cached = PremiumState(
				isPremium: wasPremium,
				source: wasPremium ? .legacy : .none,
				isVerified: false
			)
		}
		lock.unlock()
		apply(adapty: nil, apple: nil)

		adapty?.premiumObserver = { [weak self] profile in
			guard let self else { return }
			self.apply(adapty: PremiumAccess(profile: profile, levels: self.levels))
		}
		refresh()
	}

	/// PM-02: re-asks both sources. Adapty answers through `premiumObserver`, the receipt through
	/// `applyReceiptCheck`; those two are also what clear the in-flight flags.
	///
	/// TEMPORARY (premium rewrite step 2): the two requests are wrapped in bare `Task`s so this
	/// still-dual-flag `refresh()` compiles against the now-async `adapty`/`apple` protocols.
	/// Step 4 replaces this whole method with the `async let` barrier from the spec.
	public func refresh() {
		lock.lock()
		guard !awaitingAdapty, !awaitingApple else {
			lock.unlock()
			return
		}
		awaitingAdapty = adapty != nil
		awaitingApple = apple != nil
		lock.unlock()

		requestAdaptyProfile()
		if let apple {
			Task { [weak self] in
				let hasReceipt = await apple.checkReceipt()
				self?.applyReceiptCheck(hasReceipt)
			}
		}
	}

	/// TEMPORARY (premium rewrite step 2): see `refresh()`. `nil` (Adapty did not answer) leaves
	/// `awaitingAdapty` set — matching the current ceiling that step 4 removes, not fixing it here.
	private func requestAdaptyProfile() {
		guard let adapty else { return }
		Task { [weak self] in
			guard let self, let profile = await adapty.profile() else { return }
			self.apply(adapty: PremiumAccess(profile: profile, levels: self.levels))
		}
	}

	/// PM-04: Adapty answered about the premium access level.
	public func apply(adapty: PremiumAccess?) {
		lock.lock()
		awaitingAdapty = false
		lock.unlock()
		apply(adapty: adapty, apple: nil)
	}

	/// PM-04: a StoreKit purchase or restore just succeeded — that is newer than any cached
	/// Adapty answer, so drop the verified flag and let Adapty re-confirm right after.
	public func applyLocalPurchase() {
		lock.lock()
		store.cached = store.cached.map {
			PremiumState(isPremium: $0.isPremium, source: $0.source, isVerified: false, expiresAt: $0.expiresAt)
		}
		lock.unlock()
		apply(adapty: nil, apple: true)
		requestAdaptyProfile()
	}

	/// Local receipt validation finished. `nil` means it could not run, not "no access".
	/// Only `refresh()` feeds this — SU-04 row 4: the receipt has exactly one way in.
	public func applyReceiptCheck(_ hasReceipt: Bool?) {
		lock.lock()
		awaitingApple = false
		lock.unlock()
		apply(adapty: nil, apple: hasReceipt)
	}

	private func apply(adapty: PremiumAccess?, apple: Bool?) {
		lock.lock()
		let state = PremiumResolver.resolve(adapty: adapty, apple: apple, cached: store.cached, now: Date())
		// PM-02 row 2: one store write per refresh. An answer that resolves to the state already
		// cached writes nothing, so a receipt landing before Adapty cannot flash an intermediate
		// value at the UI and be overwritten a moment later.
		if state != store.cached {
			store.cached = state
		}
		// Both stores move under the same lock: the cached state and the flag mirror must never
		// disagree, which is exactly what happens if the mirror is written after unlock.
		// The mirror is assigned every time — its own setter notifies on change only.
		store.premium = state.isPremium
		lock.unlock()
	}

	// MARK: - PremiumServicing: paywalls and remote config, pass straight through to Adapty.

	public func hasPaywall(placement: String) -> Bool {
		adapty?.hasPaywall(placement: placement) ?? false
	}

	public func remoteValue<T>(placement: String, key: String) -> T? {
		adapty?.remoteValue(placement: placement, key: key)
	}

	public func logPaywallOpen(placement: String) {
		adapty?.logPaywallOpen(placement: placement)
	}

	// MARK: - PremiumServicing: stubs. TEMPORARY (premium rewrite step 2) — `restore`/`purchase`
	// land in step 5, `product`/`products` in step 6. No `fatalError()`, this is a public package.

	public func restore(completion: @escaping (RestoreOutcome) -> Void) {
		completion(.notImplemented)
	}

	public func purchase(_ productId: String, placement: String, completion: @escaping (PurchaseOutcome) -> Void) {
		completion(.notImplemented)
	}

	public func product(_ productId: String, placement: String, completion: @escaping (PremiumProduct?) -> Void) {
		completion(nil)
	}

	public func products(placement: String, completion: @escaping ([PremiumProduct]) -> Void) {
		completion([])
	}
}
