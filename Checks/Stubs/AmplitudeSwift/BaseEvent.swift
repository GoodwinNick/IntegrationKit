//
//  BaseEvent.swift
//  IntegrationKit — Checks/Stubs/AmplitudeSwift
//
//  Stand-in for `BaseEvent` (Amplitude-Swift 1.18.x). Only `idfa` — the one property
//  `AmplitudeIDFAPlugin.execute` writes. A public initializer so a check can build one directly.
//

import Foundation

public class BaseEvent {
	public var idfa: String?

	public init() {}
}
