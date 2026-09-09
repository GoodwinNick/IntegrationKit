//
//  AdaptyFlow.swift
//  IntegrationKit — Checks/Stubs
//
//  Stand-in for `AdaptyFlow` (Adapty 4.1.3, `Placements/Entities/AdaptyFlow.swift`). This is what
//  2.10.x called `AdaptyPaywall`: `getPaywall(placementId:)` became `getFlow(placementId:)`, and the
//  object it answers with is a container of paywalls rather than a paywall.
//
//  Only the four fields `AdaptyService` reads are here — `id`, `variationId`, `name` and
//  `remoteConfigs`. Left out on purpose:
//
//  * `placement` and `paywalls` (`:12`, `:24`) — the service asks for products with the FLOW
//    overload `getPaywallProducts(flow:)` (`Adapty+Completion.swift:336-343`) and logs the show
//    event with `logShowFlow(_ flow:)` (`:507-514`), so it never has to reach a single paywall. Both
//    would need `AdaptyPlacement` and `AdaptyFlowPaywall.ProductReference` behind them, neither of
//    which any row asks about.
//  * `hasViewConfiguration` (`:18-20`) — AdaptyUI only. The package does not depend on it.
//

import Foundation

public struct AdaptyFlow {
	public let id: String
	/// The identifier the dashboard attributes purchases to. `logShowFlow` needs only this
	/// (`Events/Adapty+Events.swift:106`) — the whole flow object is taken for one string.
	public let variationId: String
	public let name: String
	/// One entry per locale, empty when the dashboard has none. AD-07 row 6.
	public let remoteConfigs: [AdaptyRemoteConfig]

	public init(
		id: String = "flow",
		variationId: String = "variation",
		name: String = "flow_name",
		remoteConfigs: [AdaptyRemoteConfig] = []
	) {
		self.id = id
		self.variationId = variationId
		self.name = name
		self.remoteConfigs = remoteConfigs
	}
}
