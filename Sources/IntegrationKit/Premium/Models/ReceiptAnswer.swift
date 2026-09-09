//
//  ReceiptAnswer.swift
//  IntegrationKit
//

import Foundation

/// What the Apple receipt says. `nil` in place of this whole value means "not checked" —
/// never "no subscription". `expiresAt` is the date the newest matching subscription runs out;
/// `nil` when the receipt carries no active subscription of ours.
struct ReceiptAnswer: Equatable {
	let isActive: Bool
	let expiresAt: Date?
}
