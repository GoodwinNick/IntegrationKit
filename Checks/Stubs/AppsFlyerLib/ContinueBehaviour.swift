//
//  ContinueBehaviour.swift
//  IntegrationKit — Checks/Stubs/AppsFlyerLib
//
//  Not an SDK type: this is the knob AF-05 needs. The real `continue(_:_:)` either answers the
//  block with the objects it resolved, answers it with nothing, or — the case AF-05 row 1 is
//  about — never answers it at all. A check picks one of the three before calling
//  `AppsFlyerService.handleContinue`.
//

import Foundation

public enum ContinueBehaviour {
	/// The SDK swallows the call: the block is never invoked. AF-05 row 1.
	case neverCallsBlock
	/// The SDK answers with nothing — the real SDK's ordinary "no restoring objects" answer.
	case callsWithNil
	/// The SDK answers with these objects, untyped exactly as the real `NSArray *` is imported.
	/// AF-05 row 2 hands in a mixed array here.
	case callsWith([Any])
}
