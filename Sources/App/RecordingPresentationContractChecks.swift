#if DEBUG
import Foundation

enum RecordingPresentationContractChecks {
	static func runFromLaunchArguments() async {
		guard ProcessInfo.processInfo.arguments.contains("-recording-presentation-contract-tests") else { return }
		do {
			try freshnessChecks()
			try stateChecks()
			try decodingAndLinkChecks()
			print("RECORDING PRESENTATION CONTRACT: bounded elapsed projection, stale and legacy freezing, state labels, numeric safety, Codable compatibility, and capture-specific links passed")
			fflush(stdout)
		} catch { fatalError("RECORDING PRESENTATION CONTRACT: \(error)") }
	}

	private static let now = Date(timeIntervalSince1970: 1_900_000_000)

	private static func freshnessChecks() throws {
		let running = state(.recording, elapsed: 15)
		let fresh = running.presentation(isStale: false, now: now.addingTimeInterval(30))
		try expect(fresh.isVerified && fresh.statusText == "Recording last confirmed" && fresh.confirmedElapsed == 15
			&& fresh.timerInterval == now.addingTimeInterval(-15)...now.addingTimeInterval(90),
			"Running UI must use a bounded estimate anchored to confirmed audio, without claiming extrapolated time is captured")
		let stale = running.presentation(isStale: true, now: now.addingTimeInterval(30))
		let deadline = running.presentation(isStale: false, now: now.addingTimeInterval(90))
		let late = running.presentation(isStale: false, now: now.addingTimeInterval(10_000))
		for value in [stale, deadline, late] {
			try expect(!value.isVerified && value.timerInterval == nil && value.elapsedText == "0:15"
				&& value.statusText == "Open app to check recording" && value.symbolName == "questionmark.circle",
				"OS staleness or the local deadline must freeze every surface at confirmed elapsed and show an unverified indicator")
		}
		var heartbeat = running
		heartbeat.elapsed = 35
		heartbeat.confirmedAt = now.addingTimeInterval(20)
		heartbeat.freshUntil = now.addingTimeInterval(110)
		let updated = heartbeat.presentation(isStale: false, now: now.addingTimeInterval(25))
		try expect(updated.timerInterval?.lowerBound == fresh.timerInterval?.lowerBound
			&& updated.timerInterval?.upperBound == now.addingTimeInterval(110),
			"A progressing heartbeat must extend freshness without resetting the running clock's origin")
		heartbeat.isPaused = true
		let inconsistent = heartbeat.presentation(isStale: false, now: now.addingTimeInterval(25))
		try expect(!inconsistent.isVerified && inconsistent.timerInterval == nil, "Conflicting running/paused evidence must not animate a timer")
		heartbeat.isPaused = false
		let futureConfirmation = heartbeat.presentation(isStale: false, now: now)
		try expect(!futureConfirmation.isVerified && futureConfirmation.timerInterval == nil,
			"A clock reversal must not present a future observation as fresh recording evidence")
	}

	private static func stateChecks() throws {
		for (status, label, symbol) in [
			(RecordingActivityAttributes.Status.paused, "Paused", "pause.fill"),
			(.interrupted, "Interrupted", "exclamationmark.circle"),
			(.waitingForInput, "Waiting for microphone", "mic.slash"),
			(.stopped, "Recording stopped", "stop.fill")
		] {
			let snapshot = state(status, elapsed: 3_665)
			let presentation = snapshot.presentation(isStale: false, now: now.addingTimeInterval(10))
			try expect(presentation.isVerified && presentation.timerInterval == nil && presentation.elapsedText == "61:05"
				&& presentation.statusText == label && presentation.symbolName == symbol,
				"\(status) must show its actual state and finite captured time without a running clock")
		}
		let stopped = state(.stopped, elapsed: 27).presentation(isStale: true, now: now.addingTimeInterval(10_000))
		try expect(stopped.timerInterval == nil && stopped.statusText == "Recording stopped" && stopped.confirmedElapsed == 27,
			"A known terminal snapshot must remain stopped even if final system removal is delayed")
		for value in [-1.0, Double.infinity, Double.nan, Double.greatestFiniteMagnitude] {
			let malformed = state(.recording, elapsed: value).presentation(isStale: false, now: now)
			try expect(!malformed.isVerified && malformed.timerInterval == nil && malformed.confirmedElapsed.isFinite
				&& malformed.confirmedElapsed >= 0 && !malformed.elapsedText.isEmpty,
				"Malformed native content must never trap duration formatting or create an unbounded timer")
		}
		var resumed = state(.recording, elapsed: 45)
		resumed.confirmedAt = now.addingTimeInterval(60)
		resumed.freshUntil = now.addingTimeInterval(150)
		let afterPause = resumed.presentation(isStale: false, now: now.addingTimeInterval(60))
		try expect(afterPause.timerInterval?.lowerBound == now.addingTimeInterval(15),
			"Resuming after a pause must anchor only the saved audio duration, excluding the pause")
	}

	private static func decodingAndLinkChecks() throws {
		let decoder = JSONDecoder(), encoder = JSONEncoder()
		let legacyAttributes = try decoder.decode(RecordingActivityAttributes.self, from: Data(#"{"startedAt":123}"#.utf8))
		let legacyState = try decoder.decode(RecordingActivityAttributes.ContentState.self,
			from: Data(#"{"isPaused":false,"locationName":"Fixture","elapsed":12,"resumedAt":123}"#.utf8))
		try expect(legacyAttributes.captureID == nil && legacyState.status == nil && legacyState.confirmedAt == nil
			&& legacyState.freshUntil == nil && legacyState.presentation(isStale: false, now: now).timerInterval == nil,
			"Existing native activities must remain decodable but cannot invent freshness evidence")
		let id = UUID()
		let attributes = RecordingActivityAttributes(startedAt: now, captureID: id)
		let content = state(.interrupted, elapsed: 27)
		try expect(try decoder.decode(RecordingActivityAttributes.self, from: encoder.encode(attributes)) == attributes,
			"Capture identity must survive native Codable reconstruction")
		try expect(try decoder.decode(RecordingActivityAttributes.ContentState.self, from: encoder.encode(content)) == content,
			"Freshness and explicit capture state must survive native Codable reconstruction")
		try expect(AppDeepLink(url: attributes.recordingURL) == .recording(id),
			"The native activity must open its existing capture identity, never the new-recording widget route")
		try expect(AppDeepLink(url: legacyAttributes.recordingURL) == .recording(nil),
			"An older activity without a capture ID must open Home rather than start a replacement recording")
		for raw in ["notouroboros://recording", "notouroboros://recording?id=invalid",
			"notouroboros://recording?id=\(id)&id=\(UUID())", "notouroboros://recording?action=record"] {
			try expect(AppDeepLink(url: URL(string: raw)!) == .recording(nil),
				"Missing or ambiguous recording identity must remain a non-recording route")
		}
		try expect(AppDeepLink(url: URL(string: "notouroboros://record")!) == .record
			&& AppDeepLink(url: URL(string: "notouroboros://entry?id=\(id)")!) == .entry(id),
			"The explicit microphone widget and existing note links must retain their separate routes")
		try expect(AppDeepLink(url: URL(string: "https://recording?id=\(id)")!) == nil
			&& AppDeepLink(url: URL(string: "notouroboros://entry?id=invalid")!) == nil,
			"Unrelated or malformed note URLs must not become recording actions")
	}

	private static func state(_ status: RecordingActivityAttributes.Status, elapsed: Double) -> RecordingActivityAttributes.ContentState {
		.init(isPaused: status != .recording, locationName: "Fixture", elapsed: elapsed,
			resumedAt: status == .recording ? now : nil, status: status, confirmedAt: now, freshUntil: now.addingTimeInterval(90))
	}
	private static func expect(_ condition: Bool, _ message: String) throws { if !condition { throw Failure(message) } }
	private struct Failure: Error { var message: String; init(_ message: String) { self.message = message } }
}
#endif
