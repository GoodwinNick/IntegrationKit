//
//  ObfuscatedSecret.swift
//  IntegrationKit
//
//  XOR + base64 reveal for SDK keys an app keeps obfuscated in its own binary, so `strings`
//  on the shipped binary doesn't show the key as-is. Not cryptographic — every app needs the
//  same reveal step, so it lives here; the encrypted string and the secret stay in the app.
//

import Foundation

public enum ObfuscatedSecret {
	public static func reveal(encrypted: String, secret: String) -> String {
		guard let cipher = Data(base64Encoded: encrypted), !secret.isEmpty else { return "" }
		let key = Array(secret.utf8)
		let bytes = cipher.enumerated().map { $0.element ^ key[$0.offset % key.count] }
		return String(decoding: bytes, as: UTF8.self)
	}
}
