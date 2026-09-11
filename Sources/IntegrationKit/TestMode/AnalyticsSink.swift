//
//  AnalyticsSink.swift
//  IntegrationKit
//
//  TM-07: the one place a test run reaches outside the process. Every event and every profile
//  attribute is written as a line to a file the app's test base named, instead of being sent to
//  Amplitude — without it a UI test has no way to see that an event happened at all.
//

import Foundation

final class AnalyticsSink {

	private static let tag = "TestMode"

	/// The file this run writes to, for the one log line that says where to look.
	let path: String

	private let handle: FileHandle
	/// TM-07 row 3: writes are serialized. Lines from two queues must not interleave inside one
	/// another — a test reading half a JSON object fails for a reason that has nothing to do with it.
	private let lock = NSLock()
	private var written = 0

	/// `nil` when the file cannot be opened. There is no default path and no fallback (TM-07 row 1):
	/// a run without a path writes nothing rather than leaving files nobody reads.
	init?(path: String) {
		let manager = FileManager.default
		if !manager.fileExists(atPath: path) {
			guard manager.createFile(atPath: path, contents: nil) else { return nil }
		}
		guard let handle = FileHandle(forWritingAtPath: path) else { return nil }
		handle.seekToEndOfFile()
		self.path = path
		self.handle = handle
	}

	deinit {
		try? handle.close()
	}

	/// How many lines this sink has written. The counter is the sink's whole mutable state.
	var count: Int {
		lock.lock()
		defer { lock.unlock() }
		return written
	}

	/// One event: `name|{json}`. A repeated call writes a repeated line — the order of lines is the
	/// order of events, which is half of what a test asserts on.
	func record(_ event: String, properties: [String: Any]) {
		write("\(event)|\(Self.json(properties))")
	}

	/// One profile attribute: `profile_<key>|{"value":"…"}`. Both `setProfileValue` and
	/// `setUserProperty` land here (TM-07 row 6) — there is no other channel through which a UI test
	/// could observe a user property at all.
	///
	/// `setUserProperty` writes one pair to both dashboards, so it leaves two lines. That is the
	/// honest record of what happened and not a duplicate to be filtered: a test that cares which
	/// side got the pair has nothing else to read.
	func record(profileValue value: String, key: String) {
		record("profile_\(key)", properties: ["value": value])
	}

	private func write(_ line: String) {
		lock.lock()
		defer { lock.unlock() }
		guard let data = (line + "\n").data(using: .utf8) else { return }
		do {
			try handle.write(contentsOf: data)
			// TM-07 row 7: on disk before the call returns. A test that reads the file right after the
			// tap it triggered must see the event, and a buffered last line looks exactly like an
			// event that never happened.
			try handle.synchronize()
			written += 1
		} catch {
			ConfigurationIssues.shared.record(
				"test mode could not write to the analytics sink at \(path) — events are not being recorded: \(error.localizedDescription)",
				tag: Self.tag
			)
		}
	}

	/// Keys sorted, always. Not tidiness: a test compares the whole line, and an unsorted dictionary
	/// gives different text for the same data on the next run (TM-07 row 4). A value JSON cannot
	/// carry is written as its description rather than losing the line.
	private static func json(_ properties: [String: Any]) -> String {
		let encodable = properties.mapValues { value -> Any in
			JSONSerialization.isValidJSONObject([value]) ? value : String(describing: value)
		}
		guard let data = try? JSONSerialization.data(withJSONObject: encodable, options: [.sortedKeys]) else {
			return "{}"
		}
		return String(decoding: data, as: UTF8.self)
	}
}
