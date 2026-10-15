import AVFoundation
import Foundation
import Observation
import Speech

struct FinishedRecording: Sendable {
	var url: URL
	var duration: TimeInterval
}

enum RecordingError: LocalizedError {
	case microphonePermissionDenied
	case couldNotStart

	var errorDescription: String? {
		switch self {
		case .microphonePermissionDenied:
			"Microphone access is required to record a voice memo."
		case .couldNotStart:
			"The recording could not be started."
		}
	}
}

@MainActor
protocol AudioRecordingDevice: AnyObject {
	var isRecording: Bool { get }
	var currentTime: TimeInterval { get }
	var delegate: (any AVAudioRecorderDelegate)? { get set }
	var isMeteringEnabled: Bool { get set }
	func prepareToRecord() -> Bool
	func record() -> Bool
	func pause()
	func stop()
	func updateMeters()
	func averagePower(forChannel channelNumber: Int) -> Float
}

extension AVAudioRecorder: AudioRecordingDevice {}

@MainActor
struct RecordingHardware {
	var makeRecorder: (URL) throws -> any AudioRecordingDevice = { url in
		let settings = url.pathExtension.lowercased() == "caf"
			? RecordingAudioFormat.pcmSettings : RecordingAudioFormat.captureSettings
		return try AVAudioRecorder(url: url, settings: settings)
	}
	var activate: (AnyObject) throws -> Void = { owner in
		try AudioSessionController.shared.activate(
			owner,
			category: .record,
			mode: .default,
			options: [.allowBluetoothHFP, .bluetoothHighQualityRecording]
		)
	}
	var deactivate: (AnyObject) -> Void = { AudioSessionController.shared.deactivate($0) }
}

enum CaptureState: Equatable {
	case idle
	case starting
	case recording
	case pausedByUser
	case interrupted
	case waitingForInput
	case stopped(CaptureStopReason)
}

enum CaptureStopReason: Equatable {
	case mediaServicesReset
	case encodingFailure
	case unexpectedFinish
}

@MainActor
@Observable
final class AudioRecorder: NSObject, AVAudioRecorderDelegate {
	private(set) var state = CaptureState.idle {
		didSet { onStateChange?() }
	}
	private(set) var duration: TimeInterval = 0 {
		didSet { onStateChange?() }
	}
	private(set) var levels = Array(repeating: 0.08, count: 46)
	private(set) var wantsToRecord = false
	@ObservationIgnored var onStateChange: (() -> Void)?
	@ObservationIgnored private let permissionRequest: () async -> Bool
	@ObservationIgnored private let hardware: RecordingHardware
	@ObservationIgnored private let recoveryDelay: () async throws -> Void
	@ObservationIgnored private var recorder: (any AudioRecordingDevice)?
	@ObservationIgnored private var meterTimer: Timer?
	@ObservationIgnored private var outputURL: URL?
	@ObservationIgnored private var observationTasks: [Task<Void, Never>] = []
	@ObservationIgnored private(set) var routeRecoveryTask: Task<Void, Never>?
	@ObservationIgnored private var generation: UUID?
	@ObservationIgnored private var recoveryGeneration = UUID()
	@ObservationIgnored private var interruptionIsActive = false

	var isRecording: Bool { state == .recording }
	var hasRecording: Bool { state != .idle && state != .starting }
	var isPaused: Bool { hasRecording && !isRecording }
	var canTogglePause: Bool {
		guard hasRecording else { return false }
		if case .stopped = state { return false }
		return true
	}

	var statusMessage: String? {
		switch state {
		case .idle, .starting, .recording: nil
		case .pausedByUser: "Recording paused."
		case .interrupted: "Recording paused for an audio interruption."
		case .waitingForInput: "Recording paused until the microphone is available."
		case .stopped(.mediaServicesReset):
			"Recording stopped because the audio system restarted. You can keep what was captured."
		case .stopped(.encodingFailure), .stopped(.unexpectedFinish):
			"Recording stopped unexpectedly. You can keep what was captured."
		}
	}

	init(
		permissionRequest: @escaping () async -> Bool = { await AVAudioApplication.requestRecordPermission() },
		hardware: RecordingHardware = RecordingHardware(),
		recoveryDelay: @escaping () async throws -> Void = { try await Task.sleep(for: .milliseconds(250)) },
		observeSession: Bool = true
	) {
		self.permissionRequest = permissionRequest
		self.hardware = hardware
		self.recoveryDelay = recoveryDelay
		super.init()
		if observeSession { observeAudioSession() }
	}

	deinit {
		for task in observationTasks { task.cancel() }
		routeRecoveryTask?.cancel()
	}

	func start(at url: URL) async throws {
		guard state == .idle else { throw RecordingError.couldNotStart }
		let generation = UUID()
		self.generation = generation
		state = .starting
		do {
			guard await permissionRequest() else { throw RecordingError.microphonePermissionDenied }
			try Task.checkCancellation()
			guard self.generation == generation else { throw CancellationError() }
			try hardware.activate(self)
			let recorder = try hardware.makeRecorder(url)
			self.recorder = recorder
			outputURL = url
			recorder.delegate = self
			recorder.isMeteringEnabled = true
			guard recorder.prepareToRecord() else { throw RecordingError.couldNotStart }
			try makeFileRecoverable(at: url)
			guard recorder.record() else { throw RecordingError.couldNotStart }
			duration = 0
			levels = Array(repeating: 0.08, count: 46)
			wantsToRecord = true
			interruptionIsActive = false
			state = .recording
			startMetering()
		} catch {
			if self.generation == generation {
				recorder?.delegate = nil
				recorder?.stop()
				recorder = nil
				outputURL = nil
				self.generation = nil
				state = .idle
				hardware.deactivate(self)
			}
			throw error
		}
	}

	func togglePause() {
		guard canTogglePause else { return }
		if wantsToRecord {
			pause()
		} else {
			wantsToRecord = true
			resumeIfPossible()
		}
	}

	func pause() {
		guard canTogglePause else { return }
		wantsToRecord = false
		cancelRouteRecovery()
		duration = max(duration, recorder?.currentTime ?? 0)
		recorder?.pause()
		stopMetering()
		state = .pausedByUser
	}

	func finish() -> FinishedRecording? {
		guard hasRecording, let outputURL else { return nil }
		duration = max(duration, recorder?.currentTime ?? 0)
		stopCapture()
		self.outputURL = nil
		state = .idle
		return FinishedRecording(url: outputURL, duration: duration)
	}

	func cancel() -> URL? {
		let url = outputURL
		stopCapture()
		outputURL = nil
		state = .idle
		if let url { try? FileManager.default.removeItem(at: url) }
		return url
	}

	private func stopCapture() {
		generation = nil
		wantsToRecord = false
		interruptionIsActive = false
		cancelRouteRecovery()
		stopMetering()
		recorder?.delegate = nil
		recorder?.stop()
		recorder = nil
		hardware.deactivate(self)
	}

	private func startMetering() {
		stopMetering()
		let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
			Task { @MainActor in self?.updateMeters() }
		}
		RunLoop.main.add(timer, forMode: .common)
		meterTimer = timer
	}

	private func stopMetering() {
		meterTimer?.invalidate()
		meterTimer = nil
	}

	private func updateMeters() {
		guard let recorder, isRecording else { return }
		duration = max(duration, recorder.currentTime)
		guard recorder.isRecording else {
			state = .waitingForInput
			stopMetering()
			return
		}
		recorder.updateMeters()
		let power = recorder.averagePower(forChannel: 0)
		let normalized = max(0.08, min(1, pow(10, power / 38)))
		levels.removeFirst()
		levels.append(Double(normalized))
	}

	private func observeAudioSession() {
		let session = AVAudioSession.sharedInstance()
		observationTasks.append(Task { @MainActor [weak self] in
			for await notification in NotificationCenter.default.notifications(named: AVAudioSession.interruptionNotification, object: session) {
				self?.handleInterruption(notification)
			}
		})
		observationTasks.append(Task { @MainActor [weak self] in
			for await _ in NotificationCenter.default.notifications(named: AVAudioSession.routeChangeNotification, object: session) {
				self?.handleRouteChange()
			}
		})
		for name in [AVAudioSession.mediaServicesWereLostNotification, AVAudioSession.mediaServicesWereResetNotification] {
			observationTasks.append(Task { @MainActor [weak self] in
				for await _ in NotificationCenter.default.notifications(named: name, object: session) {
					self?.handleMediaServicesReset()
				}
			})
		}
	}

	func handleInterruption(_ notification: Notification) {
		guard hasRecording, canTogglePause,
			let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
			let type = AVAudioSession.InterruptionType(rawValue: rawType)
		else { return }
		switch type {
		case .began:
			interruptionIsActive = true
			cancelRouteRecovery()
			duration = max(duration, recorder?.currentTime ?? 0)
			recorder?.pause()
			stopMetering()
			state = wantsToRecord ? .interrupted : .pausedByUser
		case .ended:
			interruptionIsActive = false
			if wantsToRecord { resumeIfPossible() }
		@unknown default:
			break
		}
	}

	func handleRouteChange() {
		guard hasRecording, canTogglePause, wantsToRecord, !interruptionIsActive else { return }
		cancelRouteRecovery()
		let generation = self.generation
		let recoveryGeneration = self.recoveryGeneration
		if recorder?.isRecording == false {
			duration = max(duration, recorder?.currentTime ?? 0)
			state = .waitingForInput
			stopMetering()
		}
		routeRecoveryTask = Task { [weak self, recoveryDelay] in
			do { try await recoveryDelay() } catch { return }
			guard let self, !Task.isCancelled,
				self.generation == generation,
				self.recoveryGeneration == recoveryGeneration,
				self.wantsToRecord, !self.interruptionIsActive, self.canTogglePause
			else { return }
			self.routeRecoveryTask = nil
			if self.recorder?.isRecording == true {
				self.state = .recording
				self.startMetering()
			} else {
				self.resumeIfPossible()
			}
		}
	}

	private func cancelRouteRecovery() {
		recoveryGeneration = UUID()
		routeRecoveryTask?.cancel()
		routeRecoveryTask = nil
	}

	private func resumeIfPossible() {
		guard wantsToRecord, canTogglePause, let recorder else { return }
		guard !interruptionIsActive else {
			state = .interrupted
			return
		}
		do {
			try hardware.activate(self)
			guard recorder.record() else { throw RecordingError.couldNotStart }
			state = .recording
			startMetering()
		} catch {
			state = .waitingForInput
			stopMetering()
		}
	}

	func handleMediaServicesReset() {
		guard hasRecording else { return }
		AudioSessionController.shared.invalidate(self)
		stopUnexpectedly(.mediaServicesReset)
	}

	#if DEBUG
	func showStoppedDemo(duration: TimeInterval) {
		self.duration = duration
		wantsToRecord = false
		state = .stopped(.mediaServicesReset)
	}
	#endif

	func handleDeviceFinished(_ identifier: ObjectIdentifier, successfully: Bool) {
		guard let recorder, ObjectIdentifier(recorder) == identifier, hasRecording else { return }
		stopUnexpectedly(successfully ? .unexpectedFinish : .encodingFailure)
	}

	private func stopUnexpectedly(_ reason: CaptureStopReason) {
		duration = max(duration, recorder?.currentTime ?? 0)
		stopCapture()
		state = .stopped(reason)
	}

	private func makeFileRecoverable(at url: URL) throws {
		try FileManager.default.setAttributes(
			[.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
			ofItemAtPath: url.path
		)
		var url = url
		var values = URLResourceValues()
		values.isExcludedFromBackup = false
		try url.setResourceValues(values)
	}

	nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
		let identifier = ObjectIdentifier(recorder)
		Task { @MainActor [weak self] in self?.handleDeviceFinished(identifier, successfully: flag) }
	}

	nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: (any Error)?) {
		let identifier = ObjectIdentifier(recorder)
		Task { @MainActor [weak self] in self?.handleDeviceFinished(identifier, successfully: false) }
	}
}

struct TranscriptionResult: Sendable {
	let transcript: String
	let modelName: String
	let warning: String?

	init(transcript: String, modelName: String, warning: String? = nil) {
		self.transcript = transcript
		self.modelName = modelName
		self.warning = warning
	}

	func warningThatElevenLabsFailed(_ reason: String) -> TranscriptionResult {
		TranscriptionResult(transcript: transcript, modelName: modelName,
			warning: "\(reason) Apple Speech was used instead.")
	}
}

struct TranscriptionProgress: Codable, Hashable, Sendable {
	let transcript: String
	let modelName: String
}

struct TranscriptionFailure: LocalizedError, Sendable {
	enum Category: String, Codable, Sendable { case unavailable, unreadableAudio, serviceFailure }
	let category: Category
	let message: String
	let partial: TranscriptionProgress?

	init(category: Category, message: String, partial: TranscriptionProgress? = nil) {
		self.category = category
		self.message = message
		self.partial = partial
	}

	var errorDescription: String? { message }
}

typealias TranscriptionUpdate = @Sendable (TranscriptionProgress) -> Void

struct TranscriptionProviders: Sendable {
	typealias AppleProvider = @Sendable (URL, @escaping TranscriptionUpdate) async throws -> TranscriptionResult?
	var speech: AppleProvider
	var dictation: AppleProvider
	var elevenLabs: @Sendable (URL, String) async throws -> TranscriptionResult
	var bundledAPIKey: @Sendable () -> String?

	static let live = TranscriptionProviders(
		speech: AudioTranscriber.transcribeWithSpeech,
		dictation: AudioTranscriber.transcribeWithDictation,
		elevenLabs: ElevenLabsTranscriber.transcribe,
		bundledAPIKey: { ElevenLabsTranscriber.bundledAPIKey })
}

enum AudioTranscriber {
	static func transcribe(
		url: URL,
		preferElevenLabs: Bool,
		elevenLabsAPIKey: String? = nil,
		providers: TranscriptionProviders = .live,
		onUpdate: @escaping TranscriptionUpdate = { _ in }
	) async throws -> TranscriptionResult {
		try Task.checkCancellation()
		let file = try? AVAudioFile(forReading: url)
		let duration = file.map { Double($0.length) / $0.processingFormat.sampleRate } ?? 0
		file?.close()
		let timeout = Duration.seconds(max(120, (duration.isFinite ? duration : 0) * 2 + 60))
		return try await ServiceAdmission.speech.run(timeout: timeout) {
			try await performTranscription(url: url, preferElevenLabs: preferElevenLabs,
				elevenLabsAPIKey: elevenLabsAPIKey, providers: providers, onUpdate: onUpdate)
		}
	}

	static func performTranscription(
		url: URL,
		preferElevenLabs: Bool,
		elevenLabsAPIKey: String? = nil,
		providers: TranscriptionProviders = .live,
		onUpdate: @escaping TranscriptionUpdate = { _ in }
	) async throws -> TranscriptionResult {
		try Task.checkCancellation()
		guard preferElevenLabs else {
			return try await transcribeWithApple(url: url, providers: providers, onUpdate: onUpdate)
		}
		guard let apiKey = preferredAPIKey(elevenLabsAPIKey) ?? providers.bundledAPIKey() else {
			do {
				let result = try await transcribeWithApple(url: url, providers: providers, onUpdate: onUpdate)
				try Task.checkCancellation()
				return result.warningThatElevenLabsFailed("ElevenLabs is enabled, but no API key is available.")
			} catch {
				try rethrowCancellation(error)
				let failure = normalized(error)
				throw TranscriptionFailure(category: failure.category,
					message: "No ElevenLabs API key is available. " + failure.message, partial: failure.partial)
			}
		}

		let appleTask = Task {
			try await transcribeWithApple(url: url, providers: providers, onUpdate: onUpdate)
		}
		return try await withTaskCancellationHandler {
			do {
				let result = try await providers.elevenLabs(url, apiKey)
				try Task.checkCancellation()
				appleTask.cancel()
				_ = await appleTask.result
				try Task.checkCancellation()
				return result
			} catch {
				if isCancellation(error) {
					appleTask.cancel()
					_ = await appleTask.result
					throw CancellationError()
				}
				let remoteReason = error.localizedDescription
				do {
					let result = try await appleTask.value
					try Task.checkCancellation()
					return result.warningThatElevenLabsFailed("ElevenLabs transcription failed: \(remoteReason)")
				} catch {
					try rethrowCancellation(error)
					let failure = normalized(error)
					throw TranscriptionFailure(category: .serviceFailure,
						message: "ElevenLabs transcription failed: \(remoteReason). " + failure.message,
						partial: failure.partial)
				}
			}
		} onCancel: {
			appleTask.cancel()
		}
	}

	private static func preferredAPIKey(_ apiKey: String?) -> String? {
		guard let apiKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !apiKey.isEmpty else { return nil }
		return apiKey
	}

	private static func transcribeWithApple(
		url: URL,
		providers: TranscriptionProviders,
		onUpdate: @escaping TranscriptionUpdate
	) async throws -> TranscriptionResult {
		var lastFailure: TranscriptionFailure?
		var bestPartial: TranscriptionProgress?
		for provider in [providers.speech, providers.dictation] {
			try Task.checkCancellation()
			do {
				if let completed = try await provider(url, onUpdate) {
					try Task.checkCancellation()
					return completed
				}
			} catch {
				try rethrowCancellation(error)
				let failure = normalized(error)
				lastFailure = failure
				if let partial = failure.partial, partial.transcript.count > (bestPartial?.transcript.count ?? 0) {
					bestPartial = partial
				}
			}
		}
		try Task.checkCancellation()
		guard let failure = lastFailure else {
			throw TranscriptionFailure(category: .unavailable,
				message: "Apple Speech is not available for the current language on this device.")
		}
		throw TranscriptionFailure(category: failure.category,
			message: "Apple Speech could not finish transcribing this recording. " + failure.message, partial: bestPartial)
	}

	static func transcribeWithSpeech(url: URL, onUpdate: @escaping TranscriptionUpdate) async throws -> TranscriptionResult? {
		try Task.checkCancellation()
		guard SpeechTranscriber.isAvailable,
			let locale = await SpeechTranscriber.supportedLocale(equivalentTo: .current)
		else { return nil }
		let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
		return try await analyze(url: url, with: transcriber,
			modelName: "Apple SpeechTranscriber · \(locale.identifier)", onUpdate: onUpdate) { accumulator in
			for try await result in transcriber.results {
				try Task.checkCancellation()
				await accumulator.append(result.text)
			}
		}
	}

	static func transcribeWithDictation(url: URL, onUpdate: @escaping TranscriptionUpdate) async throws -> TranscriptionResult? {
		try Task.checkCancellation()
		guard let locale = await DictationTranscriber.supportedLocale(equivalentTo: .current) else { return nil }
		let transcriber = DictationTranscriber(locale: locale, preset: .longDictation)
		return try await analyze(url: url, with: transcriber,
			modelName: "Apple DictationTranscriber · \(locale.identifier)", onUpdate: onUpdate) { accumulator in
			for try await result in transcriber.results {
				try Task.checkCancellation()
				await accumulator.append(result.text)
			}
		}
	}

	static func analyze(
		url: URL,
		with module: any SpeechModule,
		modelName: String,
		onUpdate: @escaping TranscriptionUpdate,
		consume: @escaping @Sendable (TranscriptAccumulator) async throws -> Void
	) async throws -> TranscriptionResult {
		try Task.checkCancellation()
		let file: AVAudioFile
		do {
			file = try AVAudioFile(forReading: url)
			guard file.length > 0 else {
				throw TranscriptionFailure(category: .unreadableAudio, message: "The recording contains no audio samples.")
			}
		} catch {
			try rethrowCancellation(error)
			throw TranscriptionFailure(category: .unreadableAudio,
				message: "The recording could not be read. " + error.localizedDescription)
		}
		do {
			if let installation = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
				try await installation.downloadAndInstall()
			}
		} catch {
			try rethrowCancellation(error)
			throw TranscriptionFailure(category: .unavailable,
				message: "Apple Speech language assets are unavailable. " + error.localizedDescription)
		}
		try Task.checkCancellation()
		guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module], considering: file.processingFormat) else {
			throw TranscriptionFailure(category: .unavailable, message: "Apple Speech has no available audio format for this language.")
		}
		let convertedURL = FileManager.default.temporaryDirectory.appendingPathComponent("speech-input-\(UUID().uuidString).caf")
		defer { try? FileManager.default.removeItem(at: convertedURL) }
		let analysisFile: AVAudioFile
		do {
			analysisFile = try prepareAnalysisFile(file, format: format, temporaryURL: convertedURL)
		} catch {
			try rethrowCancellation(error)
			throw TranscriptionFailure(category: .unreadableAudio,
				message: "The recording could not be prepared for Apple Speech. " + error.localizedDescription)
		}
		let analyzer = SpeechAnalyzer(modules: [module])
		return try await runAnalysis(modelName: modelName, onUpdate: onUpdate, analyze: {
			guard let lastSample = try await analyzer.analyzeSequence(from: analysisFile) else {
				try Task.checkCancellation()
				throw TranscriptionFailure(category: .unreadableAudio, message: "No audio samples could be analyzed.")
			}
			try Task.checkCancellation()
			try await analyzer.finalizeAndFinish(through: lastSample)
		}, consume: consume, cancel: { await analyzer.cancelAndFinishNow() })
	}

	static func prepareAnalysisFile(_ source: AVAudioFile, format: AVAudioFormat, temporaryURL: URL) throws -> AVAudioFile {
		try Task.checkCancellation()
		source.framePosition = 0
		if source.processingFormat == format { return source }
		do {
			try writeConvertedAudio(source, format: format, url: temporaryURL)
			try Task.checkCancellation()
			return try AVAudioFile(forReading: temporaryURL, commonFormat: format.commonFormat, interleaved: format.isInterleaved)
		} catch {
			try? FileManager.default.removeItem(at: temporaryURL)
			throw error
		}
	}

	private static func writeConvertedAudio(_ source: AVAudioFile, format: AVAudioFormat, url: URL) throws {
		guard let converter = AVAudioConverter(from: source.processingFormat, to: format),
			let inputBuffer = AVAudioPCMBuffer(pcmFormat: source.processingFormat, frameCapacity: 4_096),
			let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_096)
		else { throw TranscriptionFailure(category: .unreadableAudio, message: "The audio format cannot be converted.") }
		let destination = try AVAudioFile(forWriting: url, settings: format.settings,
			commonFormat: format.commonFormat, interleaved: format.isInterleaved)
		defer { destination.close() }
		// AVAudioConverter invokes its input block synchronously during convert; these values never cross tasks.
		nonisolated(unsafe) let input = inputBuffer
		while true {
			try Task.checkCancellation()
			nonisolated(unsafe) var inputError: Error?
			var conversionError: NSError?
			let status = converter.convert(to: output, error: &conversionError) { requested, inputStatus in
				do {
					try Task.checkCancellation()
					let remaining = source.length - source.framePosition
					guard remaining > 0 else { inputStatus.pointee = .endOfStream; return nil }
					try source.read(into: input, frameCount: AVAudioFrameCount(min(Int64(min(requested, input.frameCapacity)), remaining)))
					guard input.frameLength > 0 else {
						throw TranscriptionFailure(category: .unreadableAudio, message: "The recording ended before all audio samples could be read.")
					}
					inputStatus.pointee = .haveData
					return input
				} catch {
					inputError = error
					inputStatus.pointee = .noDataNow
					return nil
				}
			}
			if let inputError { throw inputError }
			if let conversionError { throw conversionError }
			if status == .error {
				throw TranscriptionFailure(category: .unreadableAudio, message: "Audio conversion failed.")
			}
			try Task.checkCancellation()
			if output.frameLength > 0 { try destination.write(from: output) }
			if status == .endOfStream { return }
		}
	}

	static func runAnalysis(
		modelName: String,
		onUpdate: @escaping TranscriptionUpdate,
		analyze: @escaping @Sendable () async throws -> Void,
		consume: @escaping @Sendable (TranscriptAccumulator) async throws -> Void,
		cancel: @escaping @Sendable () async -> Void
	) async throws -> TranscriptionResult {
		let accumulator = TranscriptAccumulator(modelName: modelName, onUpdate: onUpdate)
		do {
			try await withTaskCancellationHandler {
				try await withThrowingTaskGroup(of: Void.self) { group in
					do {
						try Task.checkCancellation()
						group.addTask { try Task.checkCancellation(); try await analyze() }
						group.addTask { try Task.checkCancellation(); try await consume(accumulator) }
						while try await group.next() != nil {}
					} catch {
						group.cancelAll()
						await cancel()
						throw error
					}
				}
			} onCancel: {
				Task { await cancel() }
			}
			try Task.checkCancellation()
			return await accumulator.result
		} catch {
			try rethrowCancellation(error)
			let progress = await accumulator.progress
			let failure = normalized(error)
			throw TranscriptionFailure(category: failure.category, message: failure.message,
				partial: progress.transcript.isEmpty ? failure.partial : progress)
		}
	}

	private static func normalized(_ error: Error) -> TranscriptionFailure {
		(error as? TranscriptionFailure) ?? TranscriptionFailure(category: .serviceFailure, message: error.localizedDescription)
	}

	private static func isCancellation(_ error: Error) -> Bool {
		Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled
	}

	private static func rethrowCancellation(_ error: Error) throws {
		if isCancellation(error) { throw CancellationError() }
	}
}

private enum ElevenLabsTranscriber {
	private struct Response: Decodable {
		let text: String
	}

	private enum TranscriptionError: LocalizedError {
		case invalidResponse
		case requestFailed(Int)

		var errorDescription: String? {
			switch self {
			case .invalidResponse:
				"the server returned an invalid response"
			case let .requestFailed(status):
				"the server returned HTTP \(status)"
			}
		}
	}

	static var bundledAPIKey: String? {
		guard let url = Bundle.main.url(forResource: "LocalSecrets", withExtension: "xcconfig"),
			let contents = try? String(contentsOf: url, encoding: .utf8),
			let line = contents.split(whereSeparator: \.isNewline).first(where: {
				$0.trimmingCharacters(in: .whitespaces).hasPrefix("ELEVENLABS_API_KEY")
			}),
			let separator = line.firstIndex(of: "=")
		else {
			return nil
		}
		let key = line[line.index(after: separator)...]
			.trimmingCharacters(in: .whitespacesAndNewlines)
		return key.isEmpty ? nil : key
	}

	static func transcribe(url: URL, apiKey: String) async throws -> TranscriptionResult {
		try Task.checkCancellation()
		let boundary = "NoteTorus-\(UUID().uuidString)"
		let bodyURL = try multipartBody(audioURL: url, boundary: boundary)
		defer { try? FileManager.default.removeItem(at: bodyURL) }

		var request = URLRequest(url: URL(string: "https://api.elevenlabs.io/v1/speech-to-text")!)
		request.httpMethod = "POST"
		request.cachePolicy = .reloadIgnoringLocalCacheData
		request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
		request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

		let (data, response) = try await URLSession.shared.upload(for: request, fromFile: bodyURL)
		guard let response = response as? HTTPURLResponse else {
			throw TranscriptionError.invalidResponse
		}
		guard (200..<300).contains(response.statusCode) else {
			throw TranscriptionError.requestFailed(response.statusCode)
		}

		let transcript = try JSONDecoder()
			.decode(Response.self, from: data)
			.text
			.trimmingCharacters(in: .whitespacesAndNewlines)
		try Task.checkCancellation()
		return TranscriptionResult(transcript: transcript, modelName: "ElevenLabs Scribe v2")
	}

	private static func multipartBody(audioURL: URL, boundary: String) throws -> URL {
		let bodyURL = FileManager.default.temporaryDirectory
			.appendingPathComponent("elevenlabs-\(UUID().uuidString)")
			.appendingPathExtension("multipart")
		guard FileManager.default.createFile(atPath: bodyURL.path, contents: nil) else {
			throw TranscriptionError.invalidResponse
		}

		var completed = false
		defer { if !completed { try? FileManager.default.removeItem(at: bodyURL) } }
		let output = try FileHandle(forWritingTo: bodyURL)
		do {
			try writeField("model_id", value: "scribe_v2", boundary: boundary, to: output)
			try writeField("tag_audio_events", value: "false", boundary: boundary, to: output)
			try writeField("timestamps_granularity", value: "none", boundary: boundary, to: output)
			try write(
				"--\(boundary)\r\n"
					+ "Content-Disposition: form-data; name=\"file\"; filename=\"recording.m4a\"\r\n"
					+ "Content-Type: audio/mp4\r\n\r\n",
				to: output
			)

			let input = try FileHandle(forReadingFrom: audioURL)
			defer { try? input.close() }
			while let chunk = try input.read(upToCount: 1_048_576), !chunk.isEmpty {
				try Task.checkCancellation()
				try output.write(contentsOf: chunk)
			}
			try write("\r\n--\(boundary)--\r\n", to: output)
			try output.close()
			completed = true
			return bodyURL
		} catch {
			try? output.close()
			throw error
		}
	}

	private static func writeField(
		_ name: String,
		value: String,
		boundary: String,
		to output: FileHandle
	) throws {
		try write(
			"--\(boundary)\r\n"
				+ "Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n"
				+ "\(value)\r\n",
			to: output
		)
	}

	private static func write(_ value: String, to output: FileHandle) throws {
		try output.write(contentsOf: Data(value.utf8))
	}
}

actor TranscriptAccumulator {
	private var transcript = ""
	private let modelName: String
	private let onUpdate: TranscriptionUpdate

	init(modelName: String, onUpdate: @escaping TranscriptionUpdate) {
		self.modelName = modelName
		self.onUpdate = onUpdate
	}

	var result: TranscriptionResult {
		TranscriptionResult(transcript: transcript, modelName: modelName)
	}

	var progress: TranscriptionProgress {
		TranscriptionProgress(transcript: transcript, modelName: modelName)
	}

	func append(_ fragment: AttributedString) {
		guard !Task.isCancelled else { return }
		transcript += String(fragment.characters)
		onUpdate(progress)
	}
}
