//
//  DeepLinkResultStatus.swift
//  IntegrationKit — Checks/Stubs/AppsFlyerLib
//
//  Stand-in for `DeepLinkResultStatus` (AppsFlyerLib 7.0.x). All three cases —
//  `AppsFlyerService.didResolveDeepLink` switches over the full set, `@unknown default` included.
//

import Foundation

public enum DeepLinkResultStatus {
	case found
	case notFound
	case failure
}
