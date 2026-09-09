//
//  AdaptyConfiguration.swift
//  IntegrationKit — Checks/Stubs
//
//  Stand-in for `AdaptyConfiguration` and its `Builder` (Adapty 4.1.3,
//  `Configuration/AdaptyConfiguration.Builder.swift`). 4.1.3 dropped the flat
//  `activate(_:observerMode:customerUserId:dispatchQueue:)` argument list; everything now travels
//  in this object, so the stub has to carry it before `AdaptyService.configure` can be rewritten.
//
//  Only the setters `AdaptyService` uses or is about to use are here — `apiKey`, `customerUserId`,
//  `observerMode`, `adaptyAttributionEnabled`, `callbackDispatchQueue`, `transactionFinishBehavior`.
//  The rest (`idfaCollectionDisabled`, `serverCluster`, `clearDataOnBackup`, `logLevel`, the
//  `package` dev hooks) are left out on purpose: a stub that mirrored the whole builder would grow a
//  surface no check reads, and every unread line is one more thing to keep true.
//
//  The built configuration resolves the same defaults the SDK does (`AdaptyConfiguration.swift:12-19`
//  upstream: `observerMode` false, `adaptyAttributionEnabled` false, `transactionFinishBehavior`
//  `.default` — itself `.auto` at `AdaptyConfiguration.TransactionFinishBehavior.swift:10`). That is
//  what a check needs to read: "did we leave attribution off" and "who finishes the transaction" are
//  questions about the RESOLVED value, not about which setter was called.
//
//  Divergence, unavoidable: upstream every stored property of `AdaptyConfiguration` is internal
//  (`:21-33`) — the app that built one cannot read it back. The stub makes them public, because a
//  check that cannot read the configuration cannot prove anything about it.
//
//  Divergence, deliberate: upstream `AdaptyConfiguration.init(with:)` runs
//  `assert(apiKey.count >= 41 && apiKey.starts(with: "public_live"))` (`:14`). The stub does NOT
//  assert. An assert traps the whole check process, and the row it would serve (AD-01: our own
//  key-shape guard at `AdaptyService.configure`) is proven the other way round — by `activate` never
//  being called at all. A trap cannot be distinguished from a crash; a call count can.
//

import Foundation

public struct AdaptyConfiguration: Sendable {
	public enum TransactionFinishBehavior: Sendable {
		public static let `default` = TransactionFinishBehavior.auto
		case auto
		case manual
	}

	public let apiKey: String
	public let customerUserId: String?
	public let observerMode: Bool
	public let adaptyAttributionEnabled: Bool
	public let callbackDispatchQueue: DispatchQueue?
	public let transactionFinishBehavior: TransactionFinishBehavior

	public static func builder(withAPIKey apiKey: String) -> Builder {
		Builder(apiKey: apiKey)
	}
}

public extension AdaptyConfiguration {
	final class Builder {
		public private(set) var apiKey: String
		public private(set) var customerUserId: String?
		public private(set) var appAccountToken: UUID?
		public private(set) var observerMode: Bool?
		public private(set) var adaptyAttributionEnabled: Bool?
		public private(set) var callbackDispatchQueue: DispatchQueue?
		public private(set) var transactionFinishBehavior: TransactionFinishBehavior?

		init(apiKey: String) {
			self.apiKey = apiKey
		}

		@discardableResult
		public func with(apiKey key: String) -> Self {
			apiKey = key
			return self
		}

		@discardableResult
		public func with(customerUserId id: String?, withAppAccountToken token: UUID? = nil) -> Self {
			customerUserId = id
			appAccountToken = id != nil ? token : nil
			return self
		}

		@discardableResult
		public func with(observerMode mode: Bool) -> Self {
			observerMode = mode
			return self
		}

		@discardableResult
		public func with(adaptyAttributionEnabled value: Bool) -> Self {
			adaptyAttributionEnabled = value
			return self
		}

		@discardableResult
		public func with(callbackDispatchQueue queue: DispatchQueue) -> Self {
			callbackDispatchQueue = queue
			return self
		}

		@discardableResult
		public func with(transactionFinishBehavior value: TransactionFinishBehavior) -> Self {
			transactionFinishBehavior = value
			return self
		}

		public func build() -> AdaptyConfiguration {
			AdaptyConfiguration(
				apiKey: apiKey,
				customerUserId: customerUserId,
				observerMode: observerMode ?? false,
				adaptyAttributionEnabled: adaptyAttributionEnabled ?? false,
				callbackDispatchQueue: callbackDispatchQueue,
				transactionFinishBehavior: transactionFinishBehavior ?? .default
			)
		}
	}
}
