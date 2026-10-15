import ActivityKit
import Foundation

struct RecordingActivityAttributes: ActivityAttributes, Hashable, Sendable {
	enum Status: String, Codable, Hashable, Sendable {
		case recording, paused, interrupted, waitingForInput, stopped
	}

	struct ContentState: Codable, Hashable, Sendable {
		var isPaused: Bool
		var locationName: String
		var elapsed: TimeInterval
		var resumedAt: Date?
		var status: Status? = nil
		var confirmedAt: Date? = nil
		var freshUntil: Date? = nil

		private enum CodingKeys: CodingKey {
			case isPaused, locationName, elapsed, resumedAt, status, confirmedAt, freshUntil
		}

		init(isPaused: Bool, locationName: String, elapsed: TimeInterval, resumedAt: Date?,
			status: Status? = nil, confirmedAt: Date? = nil, freshUntil: Date? = nil) {
			self.isPaused = isPaused
			self.locationName = locationName
			self.elapsed = elapsed
			self.resumedAt = resumedAt
			self.status = status
			self.confirmedAt = confirmedAt
			self.freshUntil = freshUntil
		}

		init(from decoder: any Decoder) throws {
			let values = try decoder.container(keyedBy: CodingKeys.self)
			isPaused = try values.decode(Bool.self, forKey: .isPaused)
			locationName = try values.decode(String.self, forKey: .locationName)
			elapsed = try values.decode(TimeInterval.self, forKey: .elapsed)
			resumedAt = try values.decodeIfPresent(Date.self, forKey: .resumedAt)
			status = try values.decodeIfPresent(Status.self, forKey: .status)
			confirmedAt = try values.decodeIfPresent(Date.self, forKey: .confirmedAt)
			freshUntil = try values.decodeIfPresent(Date.self, forKey: .freshUntil)
		}

		func presentation(isStale: Bool, now: Date = .now) -> Presentation {
			let safeElapsed = elapsed.isFinite ? max(0, min(elapsed, Double(Int.max / 60))) : 0
			let unverified = Presentation(statusText: "Open app to check recording", symbolName: "questionmark.circle",
				confirmedElapsed: safeElapsed, timerInterval: nil, isVerified: false)
			if status == .stopped {
				return Presentation(statusText: "Recording stopped", symbolName: "stop.fill",
					confirmedElapsed: safeElapsed, timerInterval: nil, isVerified: true)
			}
			guard !isStale, let status, let confirmedAt, let freshUntil,
				elapsed.isFinite, elapsed >= 0, elapsed == safeElapsed,
				confirmedAt >= .distantPast, confirmedAt <= now, now < freshUntil, freshUntil <= .distantFuture
			else { return unverified }
			let label: String
			let symbol: String
			var interval: ClosedRange<Date>?
			switch status {
			case .recording:
				let origin = confirmedAt.addingTimeInterval(-safeElapsed)
				guard !isPaused, origin >= .distantPast else { return unverified }
				label = "Recording last confirmed"
				symbol = "waveform"
				interval = origin...freshUntil
			case .paused: label = "Paused"; symbol = "pause.fill"
			case .interrupted: label = "Interrupted"; symbol = "exclamationmark.circle"
			case .waitingForInput: label = "Waiting for microphone"; symbol = "mic.slash"
			case .stopped: label = "Recording stopped"; symbol = "stop.fill"
			}
			return Presentation(statusText: label, symbolName: symbol, confirmedElapsed: safeElapsed,
				timerInterval: interval, isVerified: true)
		}
	}

	struct Presentation: Equatable, Sendable {
		var statusText: String
		var symbolName: String
		var confirmedElapsed: TimeInterval
		var timerInterval: ClosedRange<Date>?
		var isVerified: Bool

		var elapsedText: String {
			let seconds = Int(confirmedElapsed)
			return String(format: "%ld:%02ld", seconds / 60, seconds % 60)
		}
	}

	var startedAt: Date
	var captureID: UUID? = nil

	var recordingURL: URL {
		guard let captureID else { return URL(string: "notetorus://recording")! }
		return URL(string: "notetorus://recording?id=\(captureID.uuidString)")!
	}

	private enum CodingKeys: CodingKey { case startedAt, captureID }

	init(startedAt: Date, captureID: UUID? = nil) {
		self.startedAt = startedAt
		self.captureID = captureID
	}

	init(from decoder: any Decoder) throws {
		let values = try decoder.container(keyedBy: CodingKeys.self)
		startedAt = try values.decode(Date.self, forKey: .startedAt)
		captureID = try values.decodeIfPresent(UUID.self, forKey: .captureID)
	}
}
