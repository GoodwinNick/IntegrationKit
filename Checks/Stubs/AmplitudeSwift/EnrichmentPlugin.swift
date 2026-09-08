//
//  EnrichmentPlugin.swift
//  IntegrationKit — Checks/Stubs/AmplitudeSwift
//
//  Stand-in for `EnrichmentPlugin` (Amplitude-Swift 1.18.x). `open` — unlike the rest of this
//  module — because `AmplitudeIDFAPlugin` subclasses it and overrides `execute(event:)` across
//  the module boundary; both the class and the method have to be `open` for that to compile.
//

import Foundation

open class EnrichmentPlugin {
	public init() {}

	open func execute(event: BaseEvent) -> BaseEvent? {
		event
	}
}
