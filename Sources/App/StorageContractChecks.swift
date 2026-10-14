#if DEBUG
import AVFAudio
import Foundation

@MainActor
enum StorageContractChecks {
	static func runFromLaunchArguments() async {
		guard ProcessInfo.processInfo.arguments.contains("-storage-contract-tests") else { return }
		do {
			try await migrationChecks()
			try await recoveryChecks()
			try await failureChecks()
			try await storeDeletionChecks()
			try await storeCleanupChecks()
			try await storeBulkDeletionChecks()
			try await storeMutationChecks()
			print("STORAGE CONTRACT: isolated corruption, preserved originals, idempotent migration, reserved IDs, stable recovery, incremental saves, committed exports, retryable writes/deletions, and tombstones passed")
			fflush(stdout)
		} catch { fatalError("STORAGE CONTRACT: \(error)") }
	}

	private static func migrationChecks() async throws {
		let root = try temporaryRoot()
		defer { try? FileManager.default.removeItem(at: root) }
		let first = JournalEntry(createdAt: Date(timeIntervalSince1970: 1_700_000_000), duration: 23,
			transcript: "Original transcript", headline: "Original title")
		let damagedID = UUID()
		var objects = try JSONSerialization.jsonObject(with: JSONEncoder().encode([first])) as! [[String: Any]]
		objects.append(["id": damagedID.uuidString, "transcript": 42])
		let original = try JSONSerialization.data(withJSONObject: objects)
		let legacy = root.appendingPathComponent("entries.json")
		try original.write(to: legacy)
		let repository = JournalRepository(rootURL: root)
		let loaded = try await repository.load()
		try expect(loaded.entries == [first] && !loaded.issues.isEmpty, "One invalid legacy note must not hide a healthy note")
		try expect(try Data(contentsOf: legacy) == original, "Migration must preserve legacy bytes exactly")
		try expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("records-migration-v1.complete").path), "Partial migration must remain retryable")
		var edited = first
		edited.headline = "Updated after migration"
		try await repository.save([edited])
		let restarted = try await JournalRepository(rootURL: root).load()
		try expect(restarted.entries == [edited], "Restart must prefer an updated keyed manifest over its legacy original")
		try expect(try Data(contentsOf: legacy) == original, "Editing a migrated note must not rewrite legacy storage")
		let manifest = recordURL(first.id, root: root)
		let damagedBytes = Data("{ damaged manifest".utf8)
		try damagedBytes.write(to: manifest)
		let reservedRepository = JournalRepository(rootURL: root)
		let reserved = try await reservedRepository.load()
		try expect(reserved.entries.isEmpty && !reserved.issues.isEmpty, "A damaged manifest must reserve its ID instead of reimporting older metadata")
		try expect(try Data(contentsOf: manifest) == damagedBytes, "Damaged manifest bytes must not be overwritten")
		do {
			try await reservedRepository.save([first])
			throw Failure(message: "An ordinary save overwrote a damaged manifest")
		} catch is RepositoryError {}

		let brokenRoot = try temporaryRoot()
		defer { try? FileManager.default.removeItem(at: brokenRoot) }
		let broken = Data("not a JSON library".utf8)
		try broken.write(to: brokenRoot.appendingPathComponent("entries.json"))
		let orphanID = UUID()
		try writeAudio(at: brokenRoot.appendingPathComponent("Recordings/\(orphanID.uuidString).caf"))
		let brokenLoad = try await JournalRepository(rootURL: brokenRoot).load()
		try expect(brokenLoad.entries.isEmpty && !brokenLoad.issues.isEmpty, "Unreadable legacy storage must be reported, not treated as a fresh library")
		try expect(!FileManager.default.fileExists(atPath: recordURL(orphanID, root: brokenRoot).path), "Unknown audio must not be reimported when metadata is unreadable")
		try expect(try Data(contentsOf: brokenRoot.appendingPathComponent("entries.json")) == broken, "Unreadable legacy bytes must survive startup")
	}

	private static func recoveryChecks() async throws {
		let root = try temporaryRoot()
		defer { try? FileManager.default.removeItem(at: root) }
		let repository = JournalRepository(rootURL: root)
		_ = try await repository.load()
		let draft = try await repository.beginRecording(calendarEvent: nil)
		try expect(draft.audioFilename == "\(draft.id.uuidString).\(RecordingAudioFormat.fileExtension)", "Capture must allocate its permanent UUID before audio starts")
		try await repository.checkpoint(id: draft.id, duration: 4)
		try writeAudio(at: root.appendingPathComponent("Recordings/\(draft.id.uuidString).caf"))
		try writeAudio(at: root.appendingPathComponent("Recordings/\(draft.id.uuidString).m4a"))
		let restartedRepository = JournalRepository(rootURL: root)
		let restarted = try await restartedRepository.load()
		try expect(restarted.entries.count == 1 && restarted.entries[0].id == draft.id, "CAF and M4A for one capture must recover as one stable note")
		try expect(restarted.entries[0].createdAt == draft.createdAt, "Recovery must preserve capture start time")
		let finished = try await restartedRepository.finishRecording(id: draft.id)
		try await restartedRepository.checkpoint(id: draft.id, duration: 99)
		let finishedRecord = await restartedRepository.record(id: draft.id)
		try expect(finished.id == draft.id && finishedRecord?.entry?.duration == finished.duration && finished.duration < 1,
			"A delayed checkpoint must not overwrite the duration decoded from committed audio")
		_ = try await restartedRepository.delete(id: draft.id)
		try await restartedRepository.checkpoint(id: draft.id, duration: 100)
		try await restartedRepository.save([finished])
		let deletedRecord = await restartedRepository.record(id: draft.id)
		try expect(deletedRecord?.state == .deleted && deletedRecord?.entry == nil, "Late snapshots/checkpoints must never resurrect a tombstone")
		let deletedLoad = try await JournalRepository(rootURL: root).load()
		try expect(deletedLoad.entries.isEmpty && deletedLoad.deletionReferences.contains(draft.id.uuidString), "Deletion intent must survive relaunch and suppress orphan recovery")
		try expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Recordings/\(draft.id.uuidString).caf").path), "Retry cleanup must remove all owned audio formats")
	}

	private static func failureChecks() async throws {
		let root = try temporaryRoot()
		defer { try? FileManager.default.removeItem(at: root) }
		let first = JournalEntry(duration: 12, transcript: "First", headline: "One")
		let second = JournalEntry(duration: 12, transcript: "Second", headline: "Two")
		try JSONEncoder().encode([first, second]).write(to: root.appendingPathComponent("entries.json"))
		let repository = JournalRepository(rootURL: root)
		let loaded = try await repository.load()
		try expect(loaded.entries.count == 2 && loaded.issues.isEmpty, "Healthy migration must preserve every record")
		let secondURL = recordURL(second.id, root: root)
		let before = try secondURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
		var changed = first
		changed.transcript = "Only the first note changed"
		try await repository.save([changed, second])
		let after = try secondURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
		try expect(before == after, "Saving one note must not rewrite unrelated manifests")
		let firstURL = recordURL(first.id, root: root)
		let preservedURL = root.appendingPathComponent("preserved.json")
		try FileManager.default.moveItem(at: firstURL, to: preservedURL)
		try FileManager.default.createDirectory(at: firstURL, withIntermediateDirectories: true)
		changed.headline = "Must not commit"
		var failed = false
		do { try await repository.save([changed]) }
		catch { failed = true }
		let retained = await repository.record(id: first.id)
		try expect(failed && retained?.entry?.headline == first.headline, "A real write failure must throw and retain the previously committed record")
		try FileManager.default.removeItem(at: firstURL)
		try FileManager.default.moveItem(at: preservedURL, to: firstURL)
		let reloaded = try await JournalRepository(rootURL: root).load()
		try expect(reloaded.entries.first(where: { $0.id == first.id })?.transcript == "Only the first note changed", "Incremental edits must survive relaunch after a later save fails")
	}

	private static func storeDeletionChecks() async throws {
		let root = try temporaryRoot()
		defer { try? FileManager.default.removeItem(at: root) }
		let entry = audioEntry(title: "Keep until deletion commits")
		let store = try await makeStore(entries: [entry], root: root)
		let audioURL = root.appendingPathComponent("Recordings/\(entry.audioFilename!)")
		let audioBefore = try Data(contentsOf: audioURL)
		let preservedURL = try blockManifest(entry.id, root: root)
		let deleted = await store.deleteEntry(id: entry.id)
		try expect(!deleted && store.entry(id: entry.id) == entry, "A failed deletion commit must keep its note visible and report failure")
		try expect(store.storageErrorMessage != nil, "A deletion write failure must be surfaced")
		try expect(try Data(contentsOf: audioURL) == audioBefore, "Failed deletion must leave the original audio untouched")
		let exported = await store.committedEntriesForExport()
		try expect(exported == [entry], "Failed deletion must not disappear from the committed export snapshot")
		try restoreManifest(entry.id, root: root, preservedURL: preservedURL)
		let retried = await store.deleteEntry(id: entry.id)
		try expect(retried && store.entries.isEmpty, "Retry must remove the note only after committing its tombstone")
		try expect(!FileManager.default.fileExists(atPath: audioURL.path), "Successful deletion retry must clean owned audio")
		let reloaded = try await JournalRepository(rootURL: root).load()
		try expect(reloaded.entries.isEmpty && reloaded.deletionReferences.contains(entry.id.uuidString), "Deletion retry must survive relaunch and remain queued for cloud cleanup")
	}

	private static func storeCleanupChecks() async throws {
		let root = try temporaryRoot()
		let recordings = root.appendingPathComponent("Recordings", isDirectory: true)
		defer {
			try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: recordings.path)
			try? FileManager.default.removeItem(at: root)
		}
		let entry = audioEntry(title: "Cleanup can be retried")
		let store = try await makeStore(entries: [entry], root: root)
		let audioURL = recordings.appendingPathComponent(entry.audioFilename!)
		try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: recordings.path)
		_ = await store.deleteEntry(id: entry.id)
		try expect(store.entries.isEmpty, "A committed tombstone must hide the note even when audio cleanup fails")
		try expect(store.storageErrorMessage != nil && FileManager.default.fileExists(atPath: audioURL.path), "Cleanup failure must preserve the audio and surface that work remains")
		let manifest = try JSONDecoder().decode(JournalRecord.self, from: Data(contentsOf: recordURL(entry.id, root: root)))
		try expect(manifest.state == .deleted && manifest.entry == nil && manifest.ownedAudioFilenames.contains(entry.audioFilename!), "Cleanup failure must leave durable deletion intent and audio ownership")
		let exported = await store.committedEntriesForExport()
		try expect(exported.isEmpty, "A deleted note awaiting cleanup must never be exported as live")
		try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: recordings.path)
		let reloaded = try await JournalRepository(rootURL: root).load()
		try expect(reloaded.entries.isEmpty && !FileManager.default.fileExists(atPath: audioURL.path), "Relaunch must retry cleanup without recovering deliberately deleted audio")
	}

	private static func storeBulkDeletionChecks() async throws {
		let root = try temporaryRoot()
		defer { try? FileManager.default.removeItem(at: root) }
		let first = audioEntry(title: "First")
		let blocked = audioEntry(title: "Retry this note")
		let last = audioEntry(title: "Last")
		let store = try await makeStore(entries: [first, blocked, last], root: root)
		let preservedURL = try blockManifest(blocked.id, root: root)
		let deleted = await store.clearJournal()
		try expect(!deleted && store.entries.map(\.id) == [blocked.id], "Bulk deletion must report partial failure, retaining only notes whose tombstone failed")
		try expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("Recordings/\(blocked.audioFilename!)").path), "A partial bulk deletion must preserve failed note audio")
		for entry in [first, last] {
			try expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Recordings/\(entry.audioFilename!)").path), "A blocked note must not prevent unrelated deletions from finishing")
		}
		let exported = await store.committedEntriesForExport()
		try expect(exported.map(\.id) == [blocked.id], "Bulk export must agree with the individual deletion commit outcomes")
		try restoreManifest(blocked.id, root: root, preservedURL: preservedURL)
		let retried = await store.clearJournal()
		try expect(retried && store.entries.isEmpty, "Retrying bulk deletion must finish the remaining note")
	}

	private static func storeMutationChecks() async throws {
		let root = try temporaryRoot()
		defer { try? FileManager.default.removeItem(at: root) }
		let entry = audioEntry(title: "Committed note")
		let location = JournalLocation(latitude: 41.88, longitude: -87.63, city: "Chicago")
		let store = try await makeStore(entries: [entry], root: root)
		let preservedURL = try blockManifest(entry.id, root: root)
		store.persist(.location(location), entryID: entry.id)
		await store.waitForPendingWrites()
		try expect(store.entry(id: entry.id)?.location == location, "A failed edit must remain available in the UI for retry")
		try expect(store.hasUnsavedNoteChanges && store.storageErrorMessage != nil, "A failed edit must remain explicitly unsaved")
		let committed = await store.committedEntriesForExport()
		try expect(committed == [entry], "Export must use the last committed note, excluding failed optimistic edits")
		let cloudRoot = root.appendingPathComponent("Cloud", isDirectory: true)
		let mirror = ICloudDriveMirror(containerURL: cloudRoot)
		_ = await mirror.sync(entries: committed, recordingsURL: root.appendingPathComponent("Recordings"),
			configuration: AppConfiguration(settings: store.settings, locations: [], elevenLabsAPIKey: ""),
			deletedRecordingReferences: [], revision: 1)
		let exportedFiles = try FileManager.default.contentsOfDirectory(at: cloudRoot.appendingPathComponent("Documents"), includingPropertiesForKeys: nil)
		guard let exportedURL = exportedFiles.first(where: { $0.pathExtension == "json" && $0.lastPathComponent != "config.json" }) else {
			throw Failure(message: "The committed snapshot did not produce an iCloud metadata export")
		}
		let decoder = JSONDecoder()
		decoder.dateDecodingStrategy = .iso8601
		let cloudEntry = try decoder.decode(JournalEntry.self, from: Data(contentsOf: exportedURL))
		try expect(cloudEntry.location == nil, "iCloud metadata must exclude an uncommitted edit")
		let sharedEntry = try decoder.decode(JournalEntry.self, from: committed[0].jsonData())
		try expect(sharedEntry.id == entry.id && sharedEntry.location == nil, "Share JSON built from the committed snapshot must exclude the uncommitted edit")

		try restoreManifest(entry.id, root: root, preservedURL: preservedURL)
		await store.retrySavingChanges()
		await store.waitForPendingWrites()
		try expect(!store.hasUnsavedNoteChanges, "A successful retry must clear the unsaved state")
		let retried = await store.committedEntriesForExport()
		try expect(retried.count == 1 && retried[0].location == location, "Retry must commit the retained edit")
		await store.retrySavingChanges()
		let reloaded = try await JournalRepository(rootURL: root).load()
		try expect(reloaded.entries == retried, "Committed retry results must survive relaunch")
	}

	private static func audioEntry(title: String) -> JournalEntry {
		let id = UUID()
		return JournalEntry(id: id, duration: 0.1, transcript: "Existing transcript", headline: title, audioFilename: "\(id.uuidString).m4a")
	}

	private static func makeStore(entries: [JournalEntry], root: URL) async throws -> JournalStore {
		try JSONEncoder().encode(entries).write(to: root.appendingPathComponent("entries.json"))
		for entry in entries {
			if let filename = entry.audioFilename { try writeAudio(at: root.appendingPathComponent("Recordings/\(filename)")) }
		}
		let store = JournalStore(storageRootURL: root)
		try await store.waitUntilLoaded()
		await store.waitForConfigurationWritesForContract()
		store.updateSetting(\.calendarSyncEnabled, false)
		await store.waitForConfigurationWritesForContract()
		return store
	}

	private static func blockManifest(_ id: UUID, root: URL) throws -> URL {
		let manifest = recordURL(id, root: root)
		let preserved = root.appendingPathComponent("preserved-\(id.uuidString).json")
		try FileManager.default.moveItem(at: manifest, to: preserved)
		try FileManager.default.createDirectory(at: manifest, withIntermediateDirectories: true)
		return preserved
	}

	private static func restoreManifest(_ id: UUID, root: URL, preservedURL: URL) throws {
		let manifest = recordURL(id, root: root)
		try FileManager.default.removeItem(at: manifest)
		try FileManager.default.moveItem(at: preservedURL, to: manifest)
	}

	private static func temporaryRoot() throws -> URL {
		let url = FileManager.default.temporaryDirectory.appendingPathComponent("storage-contract-\(UUID().uuidString)", isDirectory: true)
		try FileManager.default.createDirectory(at: url.appendingPathComponent("Recordings"), withIntermediateDirectories: true)
		return url
	}

	private static func recordURL(_ id: UUID, root: URL) -> URL {
		root.appendingPathComponent("Records/\(id.uuidString).json")
	}

	private static func writeAudio(at url: URL) throws {
		let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
		let settings: [String: Any] = url.pathExtension == "m4a" ? [
			AVFormatIDKey: Int(kAudioFormatMPEG4AAC), AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 1
		] : format.settings
		let file = try AVAudioFile(forWriting: url, settings: settings)
		let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4_410)!
		buffer.frameLength = 4_410
		for frame in 0..<4_410 { buffer.floatChannelData![0][frame] = sin(Float(frame) * 0.1) * 0.05 }
		try file.write(from: buffer)
		file.close()
	}

	private static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
		guard try condition() else { throw Failure(message: message) }
	}

	private struct Failure: Error, CustomStringConvertible {
		let message: String
		var description: String { message }
	}
}
#endif
