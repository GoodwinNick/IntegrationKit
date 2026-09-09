//
//  ObfuscatedSecret.swift
//  IntegrationKit
//
//  XOR + base64 reveal for SDK keys an app keeps obfuscated in its own binary, so `strings`
//  on the shipped binary doesn't show the key as-is. Not cryptographic — every app needs the
//  same reveal step, so it lives here; the encrypted string and the secret stay in the app.
//

import Foundation

/// Undoes the XOR-plus-base64 obfuscation an app ships its SDK keys under. Both halves — the
/// encrypted string and the secret — belong to the app; the package only reverses the step.
public enum ObfuscatedSecret {
	/// Base64-decodes `encrypted` and XORs it with the bytes of `secret` cycled over its length,
	/// which is how the app produced it: the encrypted string lives in the app's own binary so
	/// `strings` cannot read the key off the shipped build.
	///
	/// Returns `""` when `encrypted` is not valid base64 or `secret` is empty. A secret that does
	/// not match the one used to encrypt is not an error here — the XOR still runs and hands back a
	/// garbage string, so the mismatch shows up at the SDK the key was passed to, not at this call.
	public static func reveal(encrypted: String, secret: String) -> String {
		guard let cipher = Data(base64Encoded: encrypted), !secret.isEmpty else { return "" }
		let key = Array(secret.utf8)
		let bytes = cipher.enumerated().map { $0.element ^ key[$0.offset % key.count] }
		return String(decoding: bytes, as: UTF8.self)
	}
}
