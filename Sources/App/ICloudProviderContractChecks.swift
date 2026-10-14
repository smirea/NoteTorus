#if DEBUG
import Foundation
import Synchronization

@MainActor
enum ICloudProviderContractChecks {
	static func runFromLaunchArguments() async {
		guard ProcessInfo.processInfo.arguments.contains("-icloud-provider-contract-tests") else { return }
		do {
			try metadataAliases()
			try await configurationReads()
			try await conditionalCreation()
			try await persistedReceipts()
			try await stagingCleanup()
			try await boundedStagingCleanup()
			try await interruptedMirror(timedOut: false)
			try await interruptedMirror(timedOut: true)
			try await supersededMirror()
			print("ICLOUD PROVIDER CONTRACT: configuration classification, conditional creation, durable receipts, staging cleanup, cancellation retry, and stale-pass fencing passed")
			fflush(stdout)
		} catch {
			fatalError("ICLOUD PROVIDER CONTRACT: \(error)")
		}
	}

	private static func metadataAliases() throws {
		let fixture = try Fixture()
		defer { fixture.remove() }
		let alias = fixture.cloud.appendingPathComponent("Alias", isDirectory: true)
		try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.documents)
		let evicted = alias.appendingPathComponent("config.json")
		try expect(!FileManager.default.fileExists(atPath: fixture.configuration.path), "The metadata alias fixture must have no downloaded config")
		try expect(CloudProvider.referencesSameItem(evicted, as: fixture.configuration),
			"Metadata must recognize an evicted configuration through an aliased directory even without local config bytes")
		try expect(!CloudProvider.referencesSameItem(evicted, as: fixture.cloud.appendingPathComponent("config.json")),
			"A matching filename in another directory must not count as the requested configuration")
	}

	private static func configurationReads() async throws {
		let fixture = try Fixture()
		defer { fixture.remove() }
		let probe = ProviderProbe()
		let mirror = ICloudDriveMirror(containerURL: fixture.cloud, provider: probe.provider)
		let value = AppConfiguration(settings: JournalSettings(), elevenLabsAPIKey: "")
		let valid = try value.jsonData()
		try valid.write(to: fixture.configuration)
		guard case let .available(read) = await mirror.loadConfiguration() else { throw Failure("A current valid configuration must load") }
		try expect(read == value && probe.snapshot.downloads == 0, "Current configuration must load exactly without a download request")
		for bytes in [Data("{".utf8), Data("{}".utf8)] {
			try bytes.write(to: fixture.configuration)
			try expect(kind(await mirror.loadConfiguration()) == "damaged", "Malformed or incomplete configuration must be damaged, not defaults")
			try expect(try Data(contentsOf: fixture.configuration) == bytes, "Damaged configuration bytes must be preserved")
		}
		var future = value
		future.schemaVersion = AppConfiguration.currentSchemaVersion + 1
		let futureBytes = try future.jsonData()
		try futureBytes.write(to: fixture.configuration)
		guard case let .unsupported(version) = await mirror.loadConfiguration() else { throw Failure("A future configuration schema must remain unsupported") }
		try expect(version == future.schemaVersion && Data(contentsOf: fixture.configuration) == futureBytes, "Unsupported configuration must preserve its version and original bytes")
		try FileManager.default.removeItem(at: fixture.configuration)
		probe.change { $0.present = false }
		try expect(kind(await mirror.loadConfiguration()) == "missing", "Successful discovery and coordinated absence must report missing")
		probe.change { $0.present = true }
		try expect(kind(await mirror.loadConfiguration()) == "unavailable", "Known provider metadata with no downloaded file must not report missing")
		try valid.write(to: fixture.configuration)
		for state in [CloudProviderState.notDownloaded, .stale, .downloading] {
			let downloads = probe.snapshot.downloads
			probe.change { $0.availability = state }
			try expect(kind(await mirror.loadConfiguration()) == "unavailable" && probe.snapshot.downloads == downloads + 1,
				"Unavailable or stale provider data must request the current download instead of restoring old bytes")
		}
		probe.change { $0.availability = .current }
		guard case let .available(downloaded) = await mirror.loadConfiguration() else { throw Failure("A completed download must become restorable") }
		try expect(downloaded == value, "The downloaded current configuration must retain all source fields")
		let downloads = probe.snapshot.downloads
		probe.change { $0.availability = .conflict }
		try expect(kind(await mirror.loadConfiguration()) == "conflict" && probe.snapshot.downloads == downloads, "Conflicting versions must remain distinct from missing or unavailable data")
		var changed = value
		changed.settings.hapticsEnabled.toggle()
		let conflict = await fixture.sync(mirror, configuration: try job(changed, mode: .replace))
		try expect(!conflict.configurationExported && kind(conflict.configurationRead) == "conflict" && Data(contentsOf: fixture.configuration) == valid,
			"An unresolved conflict must prevent local replacement of the cloud configuration")
		probe.change { $0.availability = .current; $0.discoveryFails = true }
		try expect(kind(await mirror.loadConfiguration()) == "unavailable", "Discovery failure must keep restoration unresolved")
		probe.change { $0.discoveryFails = false; $0.stateFails = true }
		try expect(kind(await mirror.loadConfiguration()) == "unavailable", "Provider status failure must not be treated as absence")
		probe.change { $0.stateFails = false; $0.availability = .notDownloaded; $0.downloadFails = true }
		try expect(kind(await mirror.loadConfiguration()) == "unavailable", "A failed download request must remain retryable")
	}

	private static func conditionalCreation() async throws {
		let fixture = try Fixture()
		defer { fixture.remove() }
		var remote = AppConfiguration(settings: JournalSettings(), elevenLabsAPIKey: "")
		remote.settings.hapticsEnabled = false
		let remoteData = try remote.jsonData()
		let access = CloudFileAccess(makeCoordinator: {
			let native = CloudFileAccess.Coordination.live
			return .init(coordinate: { mode, url, accessor in
				if case .write = mode, url.lastPathComponent == "config.json" {
					try remoteData.write(to: url, options: .atomic)
				}
				try native.coordinate(mode, url, accessor)
			}, cancel: native.cancel)
		})
		let provider = CloudProvider(discover: { _ in false }, state: { _ in .current }, requestDownload: { _ in })
		let mirror = ICloudDriveMirror(containerURL: fixture.cloud, access: access, provider: provider)
		let local = AppConfiguration(settings: JournalSettings(), elevenLabsAPIKey: "")
		let result = await fixture.sync(mirror, configuration: try job(local, mode: .createIfMissing))
		guard case let .available(existing) = result.configurationRead else { throw Failure("Configuration arriving during conditional creation must be returned for restoration") }
		try expect(existing == remote && !result.configurationExported && Data(contentsOf: fixture.configuration) == remoteData,
			"Conditional creation must preserve an arriving remote configuration instead of overwriting it")
		let counts = await mirror.operationCounts
		try expect(counts.configurationWrites == 0, "Discovering an existing configuration must not count as an export")
	}

	private static func persistedReceipts() async throws {
		let fixture = try Fixture()
		defer { fixture.remove() }
		let entry = try fixture.recording()
		let firstJob = CloudNoteJob(id: entry.id, contentRevision: 1, entry: entry, deletionReferences: [], audioReceipt: nil)
		let firstMirror = ICloudDriveMirror(containerURL: fixture.cloud)
		let initial = await fixture.sync(firstMirror, jobs: [firstJob])
		guard let initialReceipt = initial.completedJobs.first, let audio = initialReceipt.audioReceipt,
			let metadata = initialReceipt.metadataReceipt else { throw Failure("A complete export must return durable audio and metadata receipts") }
		try expect(initial.failures.isEmpty && !initial.configurationExported && !FileManager.default.fileExists(atPath: fixture.configuration.path),
			"Pending configuration restoration must not block note exports or create a default configuration")
		let persistedAudio = try JSONDecoder().decode(CloudAudioReceipt.self, from: JSONEncoder().encode(audio))
		let persistedMetadata = try JSONDecoder().decode(CloudMetadataReceipt.self, from: JSONEncoder().encode(metadata))
		try expect(persistedAudio == audio && persistedMetadata == metadata, "Persisting receipts must preserve their complete file signatures")
		var resumedJob = firstJob
		resumedJob.audioReceipt = persistedAudio
		resumedJob.metadataReceipt = persistedMetadata
		let restartedMirror = ICloudDriveMirror(containerURL: fixture.cloud)
		let resumed = await fixture.sync(restartedMirror, jobs: [resumedJob])
		let unchanged = await restartedMirror.operationCounts
		try expect(resumed.failures.isEmpty && resumed.completedJobs.count == 1 && unchanged.audioCopies == 0 && unchanged.noteWrites == 0,
			"Persisted receipts must avoid audio copies and JSON rewrites after a mirror restart: \(unchanged), \(resumed.completedJobs.count) completed, \(resumed.failures.count) failures")
		var edited = entry
		edited.headline = "Changed after restart"
		resumedJob.entry = edited
		resumedJob.contentRevision = 2
		await restartedMirror.resetOperationCounts()
		let updated = await fixture.sync(restartedMirror, jobs: [resumedJob], revision: 2)
		let counts = await restartedMirror.operationCounts
		try expect(updated.failures.isEmpty && updated.exportedEntries == [edited] && counts.audioCopies == 0 && counts.noteWrites == 1,
			"A newer metadata revision must write one JSON while reusing the durable audio receipt")
		try expect(updated.completedJobs.first?.metadataReceipt?.contentRevision == 2, "The new metadata receipt must acknowledge the exported content revision")
	}

	private static func stagingCleanup() async throws {
		let fixture = try Fixture()
		defer { fixture.remove() }
		let launchedAt = Date()
		let oldTimestamp = Int64(launchedAt.addingTimeInterval(-10).timeIntervalSince1970 * 1_000)
		let recentTimestamp = Int64(launchedAt.addingTimeInterval(10).timeIntervalSince1970 * 1_000)
		let old = fixture.documents.appendingPathComponent(".talkward-\(oldTimestamp)-\(UUID().uuidString).upload")
		let recent = fixture.documents.appendingPathComponent(".talkward-\(recentTimestamp)-\(UUID().uuidString).upload")
		let protected = [recent, fixture.documents.appendingPathComponent(".\(UUID().uuidString).upload"),
			fixture.documents.appendingPathComponent(".talkward-\(UUID().uuidString).upload"),
			fixture.documents.appendingPathComponent(".talkward-not-a-uuid.upload"), fixture.documents.appendingPathComponent(".unrelated")]
		for url in [old] + protected {
			try Data("preserve".utf8).write(to: url)
			try FileManager.default.setAttributes([.modificationDate: launchedAt.addingTimeInterval(url == old ? 10 : -10)], ofItemAtPath: url.path)
		}
		let directory = fixture.documents.appendingPathComponent(".talkward-\(oldTimestamp)-\(UUID().uuidString).upload", isDirectory: true)
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		let mirror = ICloudDriveMirror(containerURL: fixture.cloud, launchedAt: launchedAt)
		let result = await fixture.sync(mirror)
		try expect(result.failures.isEmpty && !FileManager.default.fileExists(atPath: old.path), "Only owned upload staging from before launch should be cleaned")
		try expect((protected + [directory]).allSatisfy { FileManager.default.fileExists(atPath: $0.path) }, "Recent, unrelated, legacy, and directory staging lookalikes must be retained")
		let counts = await mirror.operationCounts
		try expect(counts.removals == 1, "Staging cleanup must delete exactly the abandoned owned file")
	}

	private static func interruptedMirror(timedOut: Bool) async throws {
		let fixture = try Fixture()
		defer { fixture.remove() }
		let entry = try fixture.recording()
		let export = CloudNoteJob(id: entry.id, contentRevision: 1, entry: entry, deletionReferences: [], audioReceipt: nil)
		let blocker = CopyBlocker()
		let access = CloudFileAccess(timeout: timedOut ? .milliseconds(100) : .seconds(30),
			makeCoordinator: { blocker.coordinator() })
		let mirror = ICloudDriveMirror(containerURL: fixture.cloud, access: access)
		let task = Task { await fixture.sync(mirror, jobs: [export]) }
		try await wait { blocker.snapshot.waiting }
		if !timedOut { task.cancel() }
		let cancelled = await task.value
		try expect(!cancelled.failures.isEmpty && cancelled.completedJobs.isEmpty && cancelled.exportedEntries.isEmpty && blocker.snapshot.cancelCalls == 1,
			"Cancellation or deadline expiry must reach native audio coordination and leave the job unacknowledged")
		let files = try FileManager.default.contentsOfDirectory(at: fixture.documents, includingPropertiesForKeys: nil)
		try expect(files.isEmpty, "An interrupted copy must not publish a partial pair or leave staging behind")
		let retry = await fixture.sync(mirror, jobs: [export])
		try expect(retry.failures.isEmpty && retry.exportedEntries == [entry] && retry.completedJobs.count == 1,
			"The interrupted job must complete when retried at the same revision")
	}

	private static func boundedStagingCleanup() async throws {
		let fixture = try Fixture()
		defer { fixture.remove() }
		let launchedAt = Date()
		let timestamp = Int64(launchedAt.addingTimeInterval(-10).timeIntervalSince1970 * 1_000)
		for _ in 0..<40 {
			let url = fixture.documents.appendingPathComponent(".talkward-\(timestamp)-\(UUID().uuidString).upload")
			try Data("abandoned".utf8).write(to: url)
		}
		let mirror = ICloudDriveMirror(containerURL: fixture.cloud, launchedAt: launchedAt)
		let first = await fixture.sync(mirror)
		let remaining = try FileManager.default.contentsOfDirectory(at: fixture.documents, includingPropertiesForKeys: nil)
		let firstCounts = await mirror.operationCounts
		try expect(first.failures.isEmpty && firstCounts.removals == 32 && remaining.count == 8,
			"One mirror pass must bound staging cleanup while leaving remaining disposable files for a later pass")
		await mirror.resetOperationCounts()
		let second = await fixture.sync(mirror)
		let final = try FileManager.default.contentsOfDirectory(at: fixture.documents, includingPropertiesForKeys: nil)
		let secondCounts = await mirror.operationCounts
		try expect(second.failures.isEmpty && secondCounts.removals == 8 && final.isEmpty,
			"The next mirror pass must continue unfinished prelaunch cleanup without another launch")
	}

	private static func supersededMirror() async throws {
		let fixture = try Fixture()
		defer { fixture.remove() }
		let entry = try fixture.recording()
		let original = CloudNoteJob(id: entry.id, contentRevision: 1, entry: entry, deletionReferences: [], audioReceipt: nil)
		let blocker = CopyBlocker()
		let mirror = ICloudDriveMirror(containerURL: fixture.cloud, access: CloudFileAccess(makeCoordinator: { blocker.coordinator() }))
		let old = Task { await fixture.sync(mirror, jobs: [original], revision: 1) }
		try await wait { blocker.snapshot.waiting }
		let coordinatorCalls = blocker.snapshot.coordinatorCalls
		var edited = entry
		edited.headline = "Latest committed headline"
		let replacement = CloudNoteJob(id: entry.id, contentRevision: 2, entry: edited, deletionReferences: [], audioReceipt: nil)
		let latest = Task { await fixture.sync(mirror, jobs: [replacement], revision: 2) }
		try await wait { blocker.snapshot.coordinatorCalls > coordinatorCalls }
		blocker.release()
		let obsolete = await old.value
		let result = await latest.value
		try expect(obsolete.completedJobs.isEmpty && obsolete.exportedEntries.isEmpty, "A pass superseded while audio coordination waits must not acknowledge its old snapshot")
		guard result.failures.isEmpty, let metadata = result.completedJobs.first?.metadataReceipt else {
			throw Failure("The newer pass must complete after obsolete coordination drains")
		}
		let decoder = JSONDecoder()
		decoder.dateDecodingStrategy = .iso8601
		let url = URL(fileURLWithPath: metadata.destinationDirectory).appendingPathComponent(metadata.destinationFilename)
		let exported = try decoder.decode(JournalEntry.self, from: Data(contentsOf: url))
		let counts = await mirror.operationCounts
		try expect(exported.headline == edited.headline && result.exportedEntries == [edited] && metadata.contentRevision == 2,
			"Only the newest committed snapshot may be published and acknowledged after actor reentrance")
		try expect(counts.directoryScans == 2 && counts.audioCopies == 1 && counts.noteWrites == 1 && counts.removals == 0,
			"A superseded accessor must perform no audio copy, metadata publication, or removal")
	}

	private static func wait(_ condition: () -> Bool) async throws {
		let deadline = ContinuousClock.now.advanced(by: .seconds(5))
		while !condition() {
			guard ContinuousClock.now < deadline else { throw Failure("The mirror never reached its coordination checkpoint") }
			await Task.yield()
		}
	}

	private static func job(_ value: AppConfiguration, mode: CloudConfigurationJob.Mode) throws -> CloudConfigurationJob {
		CloudConfigurationJob(value: value, data: try value.jsonData(), fingerprint: "synthetic-fixture", mode: mode)
	}
	private static func kind(_ read: ConfigurationRead?) -> String {
		switch read {
		case .available: "available"
		case .missing: "missing"
		case .unavailable: "unavailable"
		case .damaged: "damaged"
		case .unsupported: "unsupported"
		case .conflict: "conflict"
		case nil: "none"
		}
	}
	private static func expect(_ condition: Bool, _ message: String) throws { if !condition { throw Failure(message) } }
	private struct Failure: Error, CustomStringConvertible {
		let description: String
		init(_ description: String) { self.description = description }
	}
	private enum InjectedError: Error { case provider, timeout }

	private struct Fixture {
		let root: URL
		let cloud: URL
		let recordings: URL
		var documents: URL { cloud.appendingPathComponent("Documents", isDirectory: true) }
		var configuration: URL { documents.appendingPathComponent("config.json") }
		init() throws {
			root = FileManager.default.temporaryDirectory.appendingPathComponent("icloud-provider-contract-\(UUID().uuidString)", isDirectory: true)
			cloud = root.appendingPathComponent("Cloud", isDirectory: true)
			recordings = root.appendingPathComponent("Recordings", isDirectory: true)
			try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)
			try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
		}
		func recording() throws -> JournalEntry {
			let id = UUID()
			let filename = "\(id.uuidString).m4a"
			try Data(repeating: 42, count: 1_024).write(to: recordings.appendingPathComponent(filename))
			return JournalEntry(id: id, duration: 30, transcript: "Synthetic transcript", headline: "Fixture", audioFilename: filename)
		}
		func sync(_ mirror: ICloudDriveMirror, jobs: [CloudNoteJob] = [], configuration: CloudConfigurationJob? = nil, revision: Int = 1) async -> ICloudMirrorResult {
			await mirror.sync(jobs: jobs, recordingsURL: recordings, configuration: configuration, revision: revision)
		}
		func remove() { try? FileManager.default.removeItem(at: root) }
	}

	private final class ProviderProbe: Sendable {
		struct State: Sendable {
			var present = true
			var availability = CloudProviderState.current
			var downloads = 0
			var discoveryFails = false
			var stateFails = false
			var downloadFails = false
		}
		private let state = Mutex(State())
		var snapshot: State { state.withLock { $0 } }
		func change(_ mutation: (inout State) -> Void) { state.withLock { mutation(&$0) } }
		var provider: CloudProvider {
			CloudProvider(discover: { _ in
				if self.snapshot.discoveryFails { throw InjectedError.provider }
				return self.snapshot.present
			}, state: { _ in
				if self.snapshot.stateFails { throw InjectedError.provider }
				return self.snapshot.availability
			}, requestDownload: { _ in
				self.change { $0.downloads += 1 }
				if self.snapshot.downloadFails { throw InjectedError.provider }
			})
		}
	}

	private final class CopyBlocker: Sendable {
		struct State: Sendable { var waiting = false; var held = false; var cancelCalls = 0; var coordinatorCalls = 0 }
		private let state = Mutex(State())
		private let gate = DispatchSemaphore(value: 0)
		var snapshot: State { state.withLock { $0 } }
		func release() { gate.signal() }
		func coordinator() -> CloudFileAccess.Coordination {
			state.withLock { $0.coordinatorCalls += 1 }
			let native = CloudFileAccess.Coordination.live
			return .init(coordinate: { mode, url, accessor in
				let hold = self.state.withLock { value in
					guard url.pathExtension == "m4a", !value.held else { return false }
					value.held = true; value.waiting = true
					return true
				}
				if hold, self.gate.wait(timeout: .now() + 5) != .success { throw InjectedError.timeout }
				try native.coordinate(mode, url, accessor)
			}, cancel: {
				self.state.withLock { $0.cancelCalls += 1 }
				native.cancel()
				self.gate.signal()
			})
		}
	}
}
#endif
