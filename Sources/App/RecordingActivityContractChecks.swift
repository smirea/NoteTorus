#if DEBUG
import ActivityKit
import AVFoundation
import Foundation
import UIKit

@MainActor
enum RecordingActivityContractChecks {
	static func runFromLaunchArguments(session: RecordingSession) async {
		let arguments = ProcessInfo.processInfo.arguments
		guard arguments.contains(where: { $0.hasPrefix("-recording-activity-") }) else { return }
		guard arguments.contains("-demo"), !arguments.contains("-demo-recording") else {
			fatalError("Recording activity checks require -demo without -demo-recording")
		}
		if arguments.contains("-recording-activity-contract-tests") {
			do {
				try await serializedReplacement()
				try await supersededPreparation()
				try await sessionOrphansAndFailures()
				try await sessionFreshness()
				try await sessionPersistenceFailures()
				log("RECORDING ACTIVITY CONTRACT", "serialized replacement, orphan cleanup, microphone independence, freshness, accurate state, and frozen failed-save endings passed")
			} catch { fatalError("RECORDING ACTIVITY CONTRACT: \(error)") }
		}
		await nativeChecks(arguments: arguments, session: session)
	}

	private static let date = Date(timeIntervalSince1970: 2_000_000_000)

	private static func serializedReplacement() async throws {
		let backend = Backend(), first = UUID(), second = UUID()
		let manager = RecordingActivityManager(operations: backend.operations)
		manager.start(captureID: first, startedAt: date, state: state(elapsed: 0))
		await manager.waitUntilSettled()
		let firstID = backend.requests[0]
		let gate = Gate()
		backend.updateGate = gate
		manager.update(captureID: first, state: state(elapsed: 10))
		try await wait { gate.waiting }
		manager.end(captureID: first, state: state(elapsed: 12, status: .stopped))
		manager.start(captureID: second, startedAt: date, state: state(elapsed: 0))
		manager.update(captureID: first, state: state(elapsed: 200))
		manager.end(captureID: first, state: state(elapsed: 300, status: .stopped))
		try expect(backend.requests.count == 1, "A replacement must wait for the actual old update to exit")
		gate.release()
		await manager.waitUntilSettled()
		try expect(backend.live.count == 1 && backend.live.first?.attributes.captureID == second,
			"Old update/end callbacks must never replace or end the newer capture")
		try expect(backend.trace == ["request:\(firstID)", "update:\(firstID)", "end:\(firstID)", "request:\(backend.requests[1])"],
			"Native update, frozen end, and replacement request must be serialized")
		try expect(backend.endings[firstID]?.elapsed == 12 && backend.endings[firstID]?.resumedAt == nil,
			"The first valid ending must retain the final captured duration despite later stale callbacks")
		try expect(backend.maximumActiveOperations == 1, "Native recording presentation operations must never overlap")
		manager.end(captureID: second, state: state(elapsed: 1, status: .stopped))
		await manager.waitUntilSettled()
	}

	private static func supersededPreparation() async throws {
		let backend = Backend(), gate = Gate(), first = UUID(), second = UUID()
		let manager = RecordingActivityManager(operations: backend.operations)
		manager.start(captureID: first, startedAt: date, state: state(elapsed: 0), prepare: { await gate.wait(); return true })
		try await wait { gate.waiting }
		manager.end(captureID: first, state: state(elapsed: 0, status: .stopped))
		manager.start(captureID: second, startedAt: date, state: state(elapsed: 0))
		gate.release()
		await manager.waitUntilSettled()
		try expect(backend.requests.count == 1 && backend.live.first?.attributes.captureID == second,
			"A stale preparation completion must never request the discarded capture")
		manager.end(captureID: second, state: state(elapsed: 0, status: .stopped))
		await manager.waitUntilSettled()
	}

	private static func sessionOrphansAndFailures() async throws {
		for mode in ["orphans", "denied", "throwing"] {
			let root = try temporaryRoot()
			defer { try? FileManager.default.removeItem(at: root) }
			let backend = Backend(), hardware = CaptureBackend(), clock = Clock()
			let gate = Gate()
			if mode == "orphans" {
				backend.items["legacy"] = .init(id: "legacy", attributes: .init(startedAt: date), content: state(elapsed: 3))
				backend.items["previous"] = .init(id: "previous", attributes: .init(startedAt: date, captureID: UUID()), content: state(elapsed: 4))
				backend.endGate = gate
			} else if mode == "denied" { backend.enabled = false }
			else { backend.failRequest = true }
			let manager = RecordingActivityManager(operations: backend.operations)
			let store = JournalStore(storageRootURL: root)
			let recorder = AudioRecorder(permissionRequest: { true }, hardware: hardware.hardware, observeSession: false)
			let session = RecordingSession(store: store, recorder: recorder, activityManager: manager, now: { clock.now }, heartbeatInterval: .seconds(3_600))
			session.present(startsImmediately: true)
			await session.startupTask?.value
			try expect(recorder.isRecording && store.isCapturePriorityActive, "\(mode) must not block the microphone or release its capture ownership")
			if mode == "orphans" {
				try await wait { gate.waiting }
				try expect(backend.requests.isEmpty, "Recording must start while orphan cleanup is still held")
				gate.release()
				await manager.waitUntilSettled()
				try expect(backend.endings.count == 2 && backend.live.count == 1 && backend.requests.count == 1,
					"Captured legacy/current orphans must end once before the new request")
			} else {
				await manager.waitUntilSettled()
				try expect(backend.requests.isEmpty && backend.live.isEmpty, "Rejected ActivityKit work must not record a successful native receipt")
				let attempts = backend.requestAttempts
				let id = UUID(uuidString: hardware.devices[0].url.deletingPathExtension().lastPathComponent)!
				manager.update(captureID: id, state: state(elapsed: 3))
				await manager.waitUntilSettled()
				try expect(backend.requestAttempts == attempts, "An unavailable activity must not retry on every heartbeat")
			}
			try expect(await session.discard(), "Fixture capture must remain discardable after optional presentation work")
			await manager.waitUntilSettled()
			try expect(backend.live.isEmpty, "Discard must finish all recording presentation")
		}
	}

	private static func sessionFreshness() async throws {
		let root = try temporaryRoot()
		defer { try? FileManager.default.removeItem(at: root) }
		let backend = Backend(), hardware = CaptureBackend(), clock = Clock()
		let manager = RecordingActivityManager(operations: backend.operations)
		let recorder = AudioRecorder(permissionRequest: { true }, hardware: hardware.hardware, observeSession: false)
		let session = RecordingSession(store: JournalStore(storageRootURL: root), recorder: recorder, activityManager: manager,
			now: { clock.now }, heartbeatInterval: .seconds(3_600))
		session.present(startsImmediately: true)
		await session.startupTask?.value
		await manager.waitUntilSettled()
		try expect(UIApplication.shared.isIdleTimerDisabled, "Active capture must honor the enabled Keep Screen Awake setting")
		try await wait { backend.live.first?.content?.locationName == "Location unavailable" }
		let device = hardware.devices[0]
		let before = backend.updates.count
		for second in 1...20 {
			device.currentTime = Double(second)
			try await wait { recorder.duration >= Double(second) }
		}
		try expect(backend.updates.count == before, "Meter progress must not publish a native update for every sample")
		clock.advance(20)
		session.refreshActivity()
		await manager.waitUntilSettled()
		let advanced = try backend.currentContent()
		try expect(advanced.elapsed == 20, "Heartbeat must publish observed audio time")
		clock.advance(20)
		session.refreshActivity()
		await manager.waitUntilSettled()
		let wedged = try backend.currentContent()
		try expect(wedged.freshUntil == advanced.freshUntil, "A timer with no new audio progress must not renew running freshness")
		recorder.pause()
		await manager.waitUntilSettled()
		let paused = try backend.currentContent()
		try expect(paused.status == .paused && paused.elapsed == 20 && paused.resumedAt == nil, "User pause must publish frozen confirmed elapsed")
		clock.advance(20)
		session.refreshActivity()
		await manager.waitUntilSettled()
		try expect(try (backend.currentContent().freshUntil ?? .distantPast) > (paused.freshUntil ?? .distantFuture), "An owned paused session may refresh liveness without advancing audio time")
		recorder.togglePause()
		recorder.handleInterruption(interruption(.began))
		await manager.waitUntilSettled()
		try expect(try backend.currentContent().status == .interrupted, "Audio interruption must not be presented as a user pause")
		hardware.activationFails = true
		recorder.handleInterruption(interruption(.ended))
		await manager.waitUntilSettled()
		try expect(try backend.currentContent().status == .waitingForInput, "Failed recovery must truthfully show unavailable input")
		recorder.handleMediaServicesReset()
		await manager.waitUntilSettled()
		try expect(backend.live.isEmpty && backend.endings.values.first?.elapsed == 20 && !UIApplication.shared.isIdleTimerDisabled,
			"Terminal reset must end optional presentation with confirmed duration and release screen wake before Finish or Discard")
		hardware.activationFails = false
		try expect(await session.discard(), "Stopped fixture audio must remain discardable")
	}

	private static func sessionPersistenceFailures() async throws {
		for action in ["finish", "discard"] {
			let root = try temporaryRoot()
			defer { try? FileManager.default.removeItem(at: root) }
			let backend = Backend(), hardware = CaptureBackend()
			let manager = RecordingActivityManager(operations: backend.operations)
			let store = JournalStore(storageRootURL: root)
			let recorder = AudioRecorder(permissionRequest: { true }, hardware: hardware.hardware, observeSession: false)
			let session = RecordingSession(store: store, recorder: recorder, activityManager: manager, heartbeatInterval: .seconds(3_600))
			session.present(startsImmediately: true)
			await session.startupTask?.value
			await manager.waitUntilSettled()
			let device = hardware.devices[0]
			device.currentTime = 12
			try await wait { recorder.duration == 12 }
			await store.waitForPendingWrites()
			let captureID = UUID(uuidString: device.url.deletingPathExtension().lastPathComponent)!
			let recordURL = root.appendingPathComponent("Records/\(captureID.uuidString).json")
			let held = try blockWrite(at: recordURL)
			if action == "finish" { try expect(await session.finish() == nil && session.saveErrorMessage != nil, "Real blocked manifest must fail Finish") }
			else { try expect(await session.discard() == false && session.discardErrorMessage != nil, "Real blocked manifest must fail Discard") }
			await manager.waitUntilSettled()
			try expect(!recorder.isRecording && backend.live.isEmpty && backend.endings.values.first?.elapsed == 12
				&& backend.endings.values.first?.resumedAt == nil && session.canFinish && !UIApplication.shared.isIdleTimerDisabled,
				"\(action) failure must preserve retryable audio while ending presentation at actual captured elapsed and releasing screen wake")
			try restoreWrite(at: recordURL, from: held)
			try expect(await session.discard(), "Fixture retry must clean preserved capture")
		}
	}

	private static func log(_ prefix: String, _ message: String) {
		print("\(prefix): \(message)")
		fflush(stdout)
	}

	private static func state(elapsed: TimeInterval, status: RecordingActivityAttributes.Status = .recording,
		at date: Date = date, freshness: TimeInterval = 90, location: String = "Harmless fixture") -> RecordingActivityAttributes.ContentState {
		.init(isPaused: status != .recording, locationName: location, elapsed: elapsed,
			resumedAt: status == .recording ? date : nil, status: status, confirmedAt: date, freshUntil: date.addingTimeInterval(freshness))
	}

	private static let nativePrefix = "DEBUG-recording-activity-ticket17"
	private static let nativeCaptureID = UUID(uuidString: "00000000-0000-4000-8000-000000001701")!
	private static let nativeOrphanID = UUID(uuidString: "00000000-0000-4000-8000-000000001702")!

	private static func isNativeFixture(_ item: RecordingActivityOperations.Existing) -> Bool {
		item.attributes.captureID.map { [nativeCaptureID, nativeOrphanID].contains($0) } == true
			|| item.content?.locationName.hasPrefix(nativePrefix) == true
	}

	private static func nativeChecks(arguments: [String], session: RecordingSession) async {
		let live = RecordingActivityOperations.live
		if arguments.contains("-recording-activity-native-orphan-verify") {
			let initial = session.activityManager.initialActivities.filter(isNativeFixture)
			await session.activityManager.waitUntilSettled()
			do {
				try expect(initial.count == 2, "Expected exactly the two seeded startup fixture activities, found \(initial.count)")
				try await wait { !live.existing().contains { isNativeFixture($0) && $0.isLive } }
				log("RECORDING ACTIVITY NATIVE ORPHAN", "passed initial=\(initial.map(\.id).sorted()) remaining=0")
			} catch { log("RECORDING ACTIVITY NATIVE ORPHAN", "failed: \(String(reflecting: error))") }
		}
		let preview = arguments.firstIndex(of: "-recording-activity-native-preview")
		let cleanup = arguments.contains("-recording-activity-native-preview-cleanup")
		let seed = arguments.contains("-recording-activity-native-orphan-seed")
		let smoke = arguments.contains("-recording-activity-native-smoke")
		guard preview != nil || cleanup || seed || smoke else { return }
		await session.activityManager.waitUntilSettled()
		for item in live.existing().filter({ isNativeFixture($0) && $0.isLive }) {
			await live.end(item.id, state(elapsed: item.content?.elapsed ?? 0, status: .stopped, at: .now, location: nativePrefix))
		}
		if cleanup { log("RECORDING ACTIVITY NATIVE PREVIEW", "cleanup completed"); return }
		do {
			if seed {
				let now = Date.now
				let legacy = try live.request(.init(startedAt: now), state(elapsed: 8, at: now, freshness: 5, location: nativePrefix + " legacy"))
				let current = try live.request(.init(startedAt: now, captureID: nativeOrphanID), state(elapsed: 12, at: now, freshness: 5, location: nativePrefix + " orphan"))
				try await wait { live.existing().filter { isNativeFixture($0) && $0.isLive }.count == 2 }
				log("RECORDING ACTIVITY NATIVE ORPHAN READY", "pid=\(getpid()) captureID=\(nativeOrphanID) ids=\(legacy),\(current)")
				return
			}
			if let index = preview {
				guard arguments.indices.contains(index + 1) else { throw Failure("Expected running, paused, interrupted, waiting, or stale") }
				let mode = arguments[index + 1]
				let statuses: [String: RecordingActivityAttributes.Status] = ["running": .recording, "paused": .paused,
					"interrupted": .interrupted, "waiting": .waitingForInput, "stale": .recording]
				guard let status = statuses[mode] else { throw Failure("Unknown native preview state") }
				let now = Date.now
				let content = state(elapsed: 113, status: status, at: mode == "stale" ? now.addingTimeInterval(-100) : now,
					freshness: mode == "running" ? 15 : 90, location: "Chicago")
				let initial = mode == "stale" ? state(elapsed: 113, at: now, location: "Chicago") : content
				let id = try live.request(.init(startedAt: now.addingTimeInterval(-113), captureID: nativeCaptureID), initial)
				if mode == "stale" {
					try await wait { live.existing().contains { $0.id == id && $0.isLive && $0.content == initial } }
					await live.update(id, content)
				}
				try await wait { live.existing().contains { $0.id == id && $0.isLive && $0.content == content } }
				log("RECORDING ACTIVITY NATIVE PREVIEW READY", "pid=\(getpid()) state=\(mode) captureID=\(nativeCaptureID) id=\(id) confirmed=113 freshUntil=\(String(describing: content.freshUntil))")
				return
			}
			if smoke {
				let now = Date.now
				let running = state(elapsed: 10, at: now, freshness: 15, location: nativePrefix)
				let id = try live.request(.init(startedAt: now.addingTimeInterval(-10), captureID: nativeCaptureID), running)
				log("RECORDING ACTIVITY NATIVE SMOKE", "request accepted id=\(id)")
				try await wait { live.existing().contains { $0.id == id && $0.isLive && $0.content == running } }
				let paused = state(elapsed: 12, status: .paused, at: .now, location: nativePrefix)
				await live.update(id, paused)
				try await wait { live.existing().contains { $0.id == id && $0.content == paused } }
				log("RECORDING ACTIVITY NATIVE SMOKE", "pause update observed id=\(id)")
				let resumed = state(elapsed: 12, at: .now, location: nativePrefix)
				await live.update(id, resumed)
				try await wait { live.existing().contains { $0.id == id && $0.content == resumed } }
				await live.end(id, state(elapsed: 14, status: .stopped, at: .now, location: nativePrefix))
				try await wait { !live.existing().contains { $0.id == id && $0.isLive } }
				log("RECORDING ACTIVITY NATIVE SMOKE", "API lifecycle passed; rendered timer and microphone behavior require separate validation")
			}
		} catch {
			log("RECORDING ACTIVITY NATIVE", "failed: \(String(reflecting: error))")
			for item in live.existing().filter({ isNativeFixture($0) && $0.isLive }) {
				await live.end(item.id, state(elapsed: item.content?.elapsed ?? 0, status: .stopped, at: .now, location: nativePrefix))
			}
		}
	}
	private static func expect(_ condition: Bool, _ message: String) throws {
		if !condition { throw Failure(message) }
	}

	private static func wait(_ condition: @MainActor () -> Bool) async throws {
		for _ in 0..<500 {
			if condition() { return }
			try await Task.sleep(for: .milliseconds(10))
		}
		throw Failure("Timed out waiting for recording presentation")
	}

	private static func temporaryRoot() throws -> URL {
		let root = FileManager.default.temporaryDirectory.appendingPathComponent("recording-activity-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
		return root
	}

	private static func blockWrite(at url: URL) throws -> URL {
		let saved = url.appendingPathExtension("held")
		try FileManager.default.moveItem(at: url, to: saved)
		try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
		return saved
	}

	private static func restoreWrite(at url: URL, from saved: URL) throws {
		try FileManager.default.removeItem(at: url)
		try FileManager.default.moveItem(at: saved, to: url)
	}

	private static func interruption(_ type: AVAudioSession.InterruptionType) -> Notification {
		Notification(name: AVAudioSession.interruptionNotification, userInfo: [AVAudioSessionInterruptionTypeKey: type.rawValue])
	}

	private struct Failure: Error, CustomStringConvertible {
		let description: String
		init(_ description: String) { self.description = description }
	}

	@MainActor private final class Gate {
		var waiting = false
		private var continuation: CheckedContinuation<Void, Never>?
		func wait() async { await withCheckedContinuation { continuation = $0; waiting = true } }
		func release() { continuation?.resume(); continuation = nil; waiting = false }
	}

	@MainActor private final class Clock {
		var now = Date(timeIntervalSince1970: 2_000_000_000)
		func advance(_ seconds: TimeInterval) { now.addTimeInterval(seconds) }
	}

	@MainActor private final class Backend {
		var enabled = true
		var failRequest = false
		var items: [String: RecordingActivityOperations.Existing] = [:]
		var requests: [String] = []
		var requestAttempts = 0
		var updates: [RecordingActivityAttributes.ContentState] = []
		var endings: [String: RecordingActivityAttributes.ContentState] = [:]
		var trace: [String] = []
		var endGate: Gate?
		var updateGate: Gate?
		var activeOperations = 0
		var maximumActiveOperations = 0
		var live: [RecordingActivityOperations.Existing] { items.values.filter(\.isLive) }
		func currentContent() throws -> RecordingActivityAttributes.ContentState {
			guard let content = live.first?.content else { throw Failure("Missing live fixture content") }
			return content
		}
		private func begin() { activeOperations += 1; maximumActiveOperations = max(maximumActiveOperations, activeOperations) }
		var operations: RecordingActivityOperations {
			.init(enabled: { self.enabled }, existing: { self.items.values.sorted { $0.id < $1.id } }, request: { attributes, content in
				self.begin(); defer { self.activeOperations -= 1 }
				self.requestAttempts += 1
				if self.failRequest { throw Failure("Controlled request failure") }
				let id = UUID().uuidString
				self.items[id] = .init(id: id, attributes: attributes, content: content)
				self.requests.append(id); self.trace.append("request:\(id)")
				return id
			}, update: { id, content in
				self.begin(); defer { self.activeOperations -= 1 }
				let gate = self.updateGate; self.updateGate = nil
				await gate?.wait()
				self.items[id]?.content = content
				self.updates.append(content); self.trace.append("update:\(id)")
			}, end: { id, content in
				self.begin(); defer { self.activeOperations -= 1 }
				let gate = self.endGate; self.endGate = nil
				await gate?.wait()
				self.items[id]?.content = content; self.items[id]?.state = .ended
				self.endings[id] = content; self.trace.append("end:\(id)")
			})
		}
	}

	@MainActor private final class CaptureBackend {
		var devices: [CaptureDevice] = []
		var activationFails = false
		var hardware: RecordingHardware {
			RecordingHardware(makeRecorder: { url in
				let device = CaptureDevice(url: url)
				self.devices.append(device)
				return device
			}, activate: { _ in
				if self.activationFails { throw Failure("Input unavailable") }
			}, deactivate: { _ in })
		}
	}

	@MainActor private final class CaptureDevice: AudioRecordingDevice {
		let url: URL
		var isRecording = false
		var currentTime: TimeInterval = 0
		weak var delegate: (any AVAudioRecorderDelegate)?
		var isMeteringEnabled = false
		init(url: URL) { self.url = url }
		func prepareToRecord() -> Bool {
			do {
				let file = try AVAudioFile(forWriting: url, settings: RecordingAudioFormat.captureSettings)
				let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 44_100)!
				buffer.frameLength = buffer.frameCapacity
				for index in 0..<Int(buffer.frameLength) { buffer.floatChannelData![0][index] = 0 }
				for _ in 0..<12 { try file.write(from: buffer) }
				file.close()
				return true
			} catch { return false }
		}
		func record() -> Bool { isRecording = true; return true }
		func pause() { isRecording = false }
		func stop() { isRecording = false }
		func updateMeters() {}
		func averagePower(forChannel channelNumber: Int) -> Float { -20 }
	}
}
#endif
