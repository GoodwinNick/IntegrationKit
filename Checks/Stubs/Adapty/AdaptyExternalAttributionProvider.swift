//
//  AdaptyExternalAttributionProvider.swift
//  IntegrationKit — Checks/Stubs
//
//  Stand-in for `AdaptyExternalAttributionProvider` (Adapty 4.1.3,
//  `Profile/Entities/AdaptyExternalAttributionProvider.swift:15-28`) — what 2.10.x's
//  `AdaptyAttributionSource` enum became.
//
//  The change is not cosmetic: an ENUM could be switched over exhaustively and a network the SDK did
//  not know about was a compile error. This is a `RawRepresentable` struct with a public
//  `init(rawValue:)`, precisely so a backend can add a provider without an SDK release (`:10-14`).
//  Nothing stops a typo from becoming a provider nobody recognises.
//
//  Only the two networks the package names are here. `.trimmed` on the raw value (`:19`) is
//  reproduced for the same reason as in `AdaptyIntegrationIdentifier`.
//

import Foundation

public struct AdaptyExternalAttributionProvider: RawRepresentable, Hashable {
	public let rawValue: String

	public init(rawValue: String) {
		self.rawValue = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
	}

	public static let appsflyer = AdaptyExternalAttributionProvider(rawValue: "appsflyer")
	public static let custom = AdaptyExternalAttributionProvider(rawValue: "custom")
}
