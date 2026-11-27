//
//  PremiumStateStoring.swift
//  IntegrationKit
//

import Foundation

/// Where the resolved state lives between launches, plus the legacy flag screens observe.
protocol PremiumStateStoring: AnyObject {
	var cached: PremiumState? { get set }
	var premium: Bool { get set }
	/// PM-10: one verdict per access level, next to the general one. Touched only in an app that
	/// passed a product → level map.
	var levels: [String: PremiumState] { get set }
}

extension PremiumStateStoring {
	// ponytail: a store without its own `levels` keeps none, so every level reads closed. Fine for
	// the check fakes, which never pass a map; a real store implements it (`UserDefaultsPremiumStore`).
	var levels: [String: PremiumState] {
		get { [:] }
		set {}
	}
}
