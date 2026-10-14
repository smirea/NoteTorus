import Foundation
import Synchronization

private enum MirrorPass {
	@TaskLocal static var id: UUID?
}

private final class MirrorPassOwnership: Sendable {
	let current = Mutex<UUID?>(nil)
}

struct ICloudMirrorResult: Sendable {
	var completedJobs: [CloudNoteReceipt] = []
	var completedDeletions: Set<String> = []
	var exportedEntries: [JournalEntry] = []
	var configurationExported = false
	var configurationRead: ConfigurationRead?
	var failures: [String] = []
}

actor ICloudDriveMirror {
	static let containerIdentifier = "iCloud.com.stefan.talkward"

	private struct FileSignature: Equatable, Sendable {
		var size: Int64
		var modified: Date
		var fileNumber: UInt64?
	}
	private struct IndexedFile: Sendable {
		var url: URL
		var signature: FileSignature?
	}
	private struct ExportIndex: Sendable {
		var directoryURL: URL?
		var files: [String: IndexedFile] = [:]
		var exports: [UUID: Set<String>] = [:]
		var abandonedStaging: [URL] = []
		mutating func insert(_ file: IndexedFile) {
			let name = file.url.lastPathComponent
			files[name] = file
			if let id = ICloudDriveMirror.exportID(for: file.url) { exports[id, default: []].insert(name) }
		}
		mutating func remove(_ name: String) {
			guard let file = files.removeValue(forKey: name), let id = ICloudDriveMirror.exportID(for: file.url) else { return }
			exports[id]?.remove(name)
		}
	}
	private struct AudioReceipt {
		var sourceURL: URL
		var source: FileSignature
		var destination: FileSignature
	}
	private struct MetadataReceipt {
		var entry: JournalEntry
		var url: URL
		var signature: FileSignature
	}
	private struct ConfigurationReceipt: Sendable {
		var configuration: AppConfiguration
		var fingerprint: String
		var url: URL
		var signature: FileSignature
	}
	private enum MirrorError: Error { case invalidFile, invalidReference }

	private let fileManager = FileManager.default
	private let containerURL: URL?
	private let access: CloudFileAccess
	private let provider: CloudProvider
	private let launchedAt: Date
	private var cleanedStaging = false
	private var latestRevision = 0
	private let activePass = MirrorPassOwnership()
	private var audioReceipts: [URL: AudioReceipt] = [:]
	private var metadataReceipts: [UUID: MetadataReceipt] = [:]
	private var configurationReceipt: ConfigurationReceipt?

	#if DEBUG
	struct OperationCounts: Sendable {
		var directoryScans = 0
		var noteWrites = 0
		var configurationWrites = 0
		var audioCopies = 0
		var removals = 0
	}
	private(set) var operationCounts = OperationCounts()
	func resetOperationCounts() { operationCounts = OperationCounts() }
	#endif

	init(containerURL: URL? = nil, access: CloudFileAccess = CloudFileAccess(), provider: CloudProvider? = nil,
		launchedAt: Date = Date()) {
		self.containerURL = containerURL
		self.access = access
		self.provider = provider ?? (containerURL == nil ? .live : .local)
		self.launchedAt = launchedAt
	}

	func sync(
		jobs: [CloudNoteJob],
		recordingsURL: URL,
		configuration: CloudConfigurationJob?,
		deletedRecordingReferences: Set<String> = [],
		revision: Int
	) async -> ICloudMirrorResult {
		guard revision >= latestRevision else { return ICloudMirrorResult() }
		latestRevision = revision
		let id = UUID()
		activePass.current.withLock { $0 = id }
		return await MirrorPass.$id.withValue(id) {
			await performSync(jobs: jobs, recordingsURL: recordingsURL, configuration: configuration,
				deletedRecordingReferences: deletedRecordingReferences)
		}
	}

	private func performSync(jobs: [CloudNoteJob], recordingsURL: URL, configuration: CloudConfigurationJob?,
		deletedRecordingReferences: Set<String>) async -> ICloudMirrorResult {
		var result = ICloudMirrorResult()
		guard var documentsURL = documentsURL() else {
			result.failures.append("iCloud Drive is unavailable.")
			return result
		}
		var index: ExportIndex
		do {
			try Task.checkCancellation()
			index = try await scan(documentsURL)
			documentsURL = index.directoryURL ?? documentsURL
			if !cleanedStaging {
				var cleanupFailed = false
				for url in index.abandonedStaging.prefix(32) {
					do { try await remove(url) }
					catch is CancellationError { throw CancellationError() }
					catch { cleanupFailed = true }
				}
				cleanedStaging = !cleanupFailed && index.abandonedStaging.count <= 32
				if cleanupFailed { result.failures.append("Some temporary iCloud export files could not be cleaned up. Cleanup will retry.") }
			}
		} catch {
			result.failures.append("iCloud Drive exports could not be read. Pending changes will be retried.")
			return result
		}

		let references = jobs.filter { $0.entry == nil }.reduce(into: deletedRecordingReferences) {
			$0.formUnion($1.deletionReferences)
			$0.insert($1.id.uuidString)
		}
		let deletedIDs = Set(references.compactMap(Self.referenceID))
		for reference in references.sorted() {
			do {
				try Task.checkCancellation()
				if let id = Self.referenceID(reference) {
					try await removeExports(for: [id], keeping: [], index: &index)
					metadataReceipts[id] = nil
				} else if !Self.isStagingReference(reference) {
					throw MirrorError.invalidReference
				}
				result.completedDeletions.insert(reference)
			} catch {
				result.failures.append("An iCloud Drive deletion could not be completed. It remains pending.")
			}
		}
		for job in jobs where job.entry == nil {
			if job.deletionReferences.union([job.id.uuidString]).isSubset(of: result.completedDeletions) {
				result.completedJobs.append(CloudNoteReceipt(job: job, audioReceipt: nil))
			}
		}
		if let configuration {
			do {
				let outcome = try await export(configuration, documentsURL: documentsURL, index: &index)
				result.configurationRead = outcome.read
				result.configurationExported = outcome.exported
			} catch {
				result.configurationRead = .unavailable("The saved configuration could not be exported to iCloud Drive.")
			}
			if !result.configurationExported { result.failures.append("Configuration export remains pending.") }
		}
		for job in jobs {
			guard let entry = job.entry else { continue }
			guard !deletedIDs.contains(entry.id),
				entry.audioFilename.flatMap(Self.referenceID).map({ !deletedIDs.contains($0) }) ?? true,
				entry.audioFilename.map({ URL(fileURLWithPath: $0).pathExtension.lowercased() == "m4a" }) == true
			else { continue }
			do {
				let receipt = try await export(job, entry: entry, recordingsURL: recordingsURL,
					documentsURL: documentsURL, index: &index)
				result.exportedEntries.append(entry)
				result.completedJobs.append(receipt)
			} catch {
				result.failures.append("Recording \(entry.id.uuidString) could not be exported completely to iCloud Drive.")
			}
		}
		let currentIDs = Set(jobs.compactMap(\.entry).map(\.id)).subtracting(deletedIDs)
		metadataReceipts = metadataReceipts.filter { currentIDs.contains($0.key) }
		audioReceipts = audioReceipts.filter { url, _ in
			url.deletingLastPathComponent() == documentsURL
				&& Self.exportID(for: url).map(currentIDs.contains) == true
				&& index.files[url.lastPathComponent]?.signature != nil
		}
		return result
	}

	private func scan(_ documentsURL: URL) async throws -> ExportIndex {
		#if DEBUG
		operationCounts.directoryScans += 1
		#endif
		let launchedAt = launchedAt
		return try await coordinated(.write, at: documentsURL) { url, check in
			try check()
			try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
			let urls = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
			var index = ExportIndex()
			index.directoryURL = url.resolvingSymlinksInPath()
			for url in urls {
				try check()
				if url.lastPathComponent == "config.json" || Self.exportID(for: url) != nil {
					index.insert(try Self.indexedFile(at: url))
				} else if let created = Self.uploadCreatedAt(url), created < launchedAt,
					try Self.indexedFile(at: url).signature != nil { index.abandonedStaging.append(url) }
			}
			return index
		}
	}

	nonisolated private static func indexedFile(at url: URL) throws -> IndexedFile {
		let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
		guard attributes[.type] as? FileAttributeType == .typeRegular,
			let size = attributes[.size] as? NSNumber, let modified = attributes[.modificationDate] as? Date
		else { return IndexedFile(url: url, signature: nil) }
		return IndexedFile(url: url.resolvingSymlinksInPath(), signature: FileSignature(size: size.int64Value, modified: modified,
			fileNumber: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value))
	}

	private func export(_ job: CloudConfigurationJob, documentsURL: URL, index: inout ExportIndex) async throws
		-> (read: ConfigurationRead, exported: Bool) {
		let url = documentsURL.appendingPathComponent("config.json")
		let provider = provider
		let knownPresent = job.mode == .createIfMissing ? try await provider.discover(url) : false
		if let unavailable = try Self.configurationAvailability(at: url, provider: provider) { return (unavailable, false) }
		let receipt = configurationReceipt
		let cached = receipt?.configuration == job.value && receipt?.fingerprint == job.fingerprint && receipt?.url == url
			&& receipt?.signature == index.files[url.lastPathComponent]?.signature
		let outcome: (ConfigurationRead, IndexedFile?, Bool) = try await coordinated(.write, at: url) { url, check in
			try check()
			if job.mode == .createIfMissing {
				let existing = try Self.readConfiguration(at: url, provider: provider)
				if case .missing = existing {
					if knownPresent { return (.unavailable("The iCloud configuration is waiting to download."), nil, false) }
				} else { return (existing, nil, false) }
			} else if let unavailable = try Self.configurationAvailability(at: url, provider: provider) {
				return (unavailable, nil, false)
			}
			if cached, let file = try? Self.indexedFile(at: url), file.signature == receipt?.signature {
				return (.available(job.value), file, false)
			}
			try Self.requireRegularDestination(url)
			try check()
			try job.data.write(to: url, options: .atomic)
			return (.available(job.value), try Self.indexedFile(at: url), true)
		}
		if let file = outcome.1, let signature = file.signature {
			index.insert(file)
			configurationReceipt = ConfigurationReceipt(configuration: job.value, fingerprint: job.fingerprint,
				url: file.url, signature: signature)
			#if DEBUG
			if outcome.2 { operationCounts.configurationWrites += 1 }
			#endif
			return (outcome.0, true)
		}
		return (outcome.0, false)
	}

	private func export(_ job: CloudNoteJob, entry: JournalEntry, recordingsURL: URL, documentsURL: URL,
		index: inout ExportIndex) async throws -> CloudNoteReceipt {
		try Task.checkCancellation()
		guard let filename = entry.audioFilename, URL(fileURLWithPath: filename).lastPathComponent == filename else {
			throw MirrorError.invalidFile
		}
		let sourceURL = recordingsURL.appendingPathComponent(filename)
		guard let source = try Self.indexedFile(at: sourceURL).signature, source.size > 0 else { throw MirrorError.invalidFile }
		let audioURL = documentsURL.appendingPathComponent(exportStem(for: entry) + ".m4a")
		if let receipt = job.audioReceipt, receipt.sourceFilename == filename, receipt.destinationDirectory == documentsURL.path,
			receipt.destinationFilename == audioURL.lastPathComponent {
			audioReceipts[audioURL] = AudioReceipt(sourceURL: sourceURL,
				source: FileSignature(size: receipt.sourceSize, modified: receipt.sourceModifiedAt, fileNumber: receipt.sourceFileNumber),
				destination: FileSignature(size: receipt.destinationSize, modified: receipt.destinationModifiedAt,
					fileNumber: receipt.destinationFileNumber))
		}
		let audio = try await mirrorAudio(from: sourceURL, signature: source, to: audioURL, index: &index)
		let metadataURL = audio.url.deletingPathExtension().appendingPathExtension("json")
		if let receipt = job.metadataReceipt, receipt.contentRevision == job.contentRevision,
			receipt.destinationDirectory == metadataURL.deletingLastPathComponent().path,
			receipt.destinationFilename == metadataURL.lastPathComponent {
			metadataReceipts[entry.id] = MetadataReceipt(entry: entry, url: metadataURL,
				signature: FileSignature(size: receipt.size, modified: receipt.modifiedAt, fileNumber: receipt.fileNumber))
		}
		let cachedMetadata = metadataReceipts[entry.id]
		if cachedMetadata?.entry != entry || cachedMetadata?.url != metadataURL
			|| cachedMetadata?.signature != index.files[metadataURL.lastPathComponent]?.signature {
			var exported = entry
			exported.audioFilename = audio.url.lastPathComponent
			let data = try exported.jsonData()
			let file = try await coordinated(.write, at: metadataURL) { url, check in
				try Self.requireRegularDestination(url)
				try check()
				try data.write(to: url, options: .atomic)
				return try Self.indexedFile(at: url)
			}
			#if DEBUG
			operationCounts.noteWrites += 1
			#endif
			guard let signature = file.signature else { throw MirrorError.invalidFile }
			index.insert(file)
			metadataReceipts[entry.id] = MetadataReceipt(entry: entry, url: file.url, signature: signature)
		}
		var ids: Set<UUID> = [entry.id]
		if let legacyID = Self.referenceID(filename) { ids.insert(legacyID) }
		try await removeExports(for: ids, keeping: [audio.url.lastPathComponent, metadataURL.lastPathComponent], index: &index)
		guard let destination = audio.signature, let metadata = metadataReceipts[entry.id] else { throw MirrorError.invalidFile }
		let audioReceipt = CloudAudioReceipt(sourceFilename: filename, sourceSize: source.size, sourceModifiedAt: source.modified,
			sourceFileNumber: source.fileNumber, destinationDirectory: audio.url.deletingLastPathComponent().path,
			destinationFilename: audio.url.lastPathComponent, destinationSize: destination.size,
			destinationModifiedAt: destination.modified, destinationFileNumber: destination.fileNumber)
		let metadataReceipt = CloudMetadataReceipt(contentRevision: job.contentRevision,
			destinationDirectory: metadata.url.deletingLastPathComponent().path, destinationFilename: metadata.url.lastPathComponent,
			size: metadata.signature.size, modifiedAt: metadata.signature.modified, fileNumber: metadata.signature.fileNumber)
		return CloudNoteReceipt(job: job, audioReceipt: audioReceipt, metadataReceipt: metadataReceipt)
	}

	private func mirrorAudio(from sourceURL: URL, signature: FileSignature, to destinationURL: URL,
		index: inout ExportIndex) async throws -> IndexedFile {
		if let receipt = audioReceipts[destinationURL], receipt.sourceURL == sourceURL, receipt.source == signature,
			let file = index.files[destinationURL.lastPathComponent], file.signature == receipt.destination { return file }
		let file = try await coordinated(.write, at: destinationURL) { url, check in
			try check()
			try Self.requireRegularDestination(url)
			let timestamp = Int64(Date().timeIntervalSince1970 * 1_000)
			let stagingURL = url.deletingLastPathComponent().appendingPathComponent(".talkward-\(timestamp)-\(UUID().uuidString).upload")
			defer { try? FileManager.default.removeItem(at: stagingURL) }
			try FileManager.default.copyItem(at: sourceURL, to: stagingURL)
			try check()
			guard try Self.indexedFile(at: sourceURL).signature == signature else { throw MirrorError.invalidFile }
			if FileManager.default.fileExists(atPath: url.path) {
				_ = try FileManager.default.replaceItemAt(url, withItemAt: stagingURL)
			} else {
				try FileManager.default.moveItem(at: stagingURL, to: url)
			}
			return try Self.indexedFile(at: url)
		}
		#if DEBUG
		operationCounts.audioCopies += 1
		#endif
		guard let destination = file.signature else { throw MirrorError.invalidFile }
		index.insert(file)
		audioReceipts[file.url] = AudioReceipt(sourceURL: sourceURL, source: signature, destination: destination)
		return file
	}

	nonisolated private static func requireRegularDestination(_ url: URL) throws {
		do { if try indexedFile(at: url).signature == nil { throw MirrorError.invalidFile } }
		catch where isMissing(error) {}
	}

	private func removeExports(for ids: Set<UUID>, keeping names: Set<String>, index: inout ExportIndex) async throws {
		let obsolete = ids.reduce(into: Set<String>()) { $0.formUnion(index.exports[$1] ?? []) }.subtracting(names)
		for name in obsolete.sorted() {
			try Task.checkCancellation()
			guard let file = index.files[name], file.signature != nil else { throw MirrorError.invalidFile }
			try await remove(file.url)
			index.remove(name)
			audioReceipts[file.url] = nil
		}
	}

	private func remove(_ url: URL) async throws {
		let removed = try await coordinated(.delete, at: url) { url, check in
			do {
				try Self.requireRegularDestination(url)
				try check()
				try FileManager.default.removeItem(at: url)
				return true
			} catch where Self.isMissing(error) { return false }
		}
		#if DEBUG
		if removed { operationCounts.removals += 1 }
		#endif
	}

	private func coordinated<T: Sendable>(_ kind: CloudFileAccess.Access, at url: URL,
		operation: @escaping @Sendable (URL, @Sendable () throws -> Void) throws -> T) async throws -> T {
		let expected = MirrorPass.id
		let activePass = activePass
		return try await access.perform(kind, at: url) { url, check in
			try check()
			if let expected, activePass.current.withLock({ $0 }) != expected { throw CancellationError() }
			return try operation(url) {
				try check()
				if let expected, activePass.current.withLock({ $0 }) != expected { throw CancellationError() }
			}
		}
	}

	nonisolated private static func referenceID(_ reference: String) -> UUID? {
		guard URL(fileURLWithPath: reference).lastPathComponent == reference else { return nil }
		let url = URL(fileURLWithPath: reference)
		guard url.pathExtension.isEmpty || ["aac", "caf", "m4a", "json"].contains(url.pathExtension.lowercased()) else { return nil }
		return canonicalUUID(url.deletingPathExtension().lastPathComponent)
	}

	nonisolated private static func canonicalUUID(_ text: String) -> UUID? {
		guard let id = UUID(uuidString: text), id.uuidString.caseInsensitiveCompare(text) == .orderedSame else { return nil }
		return id
	}

	nonisolated private static func exportID(for url: URL) -> UUID? {
		guard ["m4a", "json"].contains(url.pathExtension.lowercased()) else { return nil }
		let stem = url.deletingPathExtension().lastPathComponent
		if let id = canonicalUUID(stem) { return id }
		guard stem.count > 38, stem.dropLast(36).hasSuffix("__"), let id = canonicalUUID(String(stem.suffix(36))) else { return nil }
		let prefix = String(stem.dropLast(38))
		guard prefix.range(of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}_.+$"#, options: .regularExpression) != nil else { return nil }
		return id
	}

	nonisolated private static func isStagingReference(_ reference: String) -> Bool {
		guard reference.hasPrefix("."), reference.hasSuffix(".finalizing.m4a") else { return false }
		let stem = String(reference.dropFirst().dropLast(".finalizing.m4a".count))
		return stem.count == 73 && stem.dropFirst(36).hasPrefix("-")
			&& canonicalUUID(String(stem.prefix(36))) != nil && canonicalUUID(String(stem.suffix(36))) != nil
	}

	nonisolated private static func isMissing(_ error: Error) -> Bool {
		let error = error as NSError
		return error.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code)
	}

	nonisolated private static func uploadCreatedAt(_ url: URL) -> Date? {
		let name = url.lastPathComponent
		guard name.hasPrefix(".talkward-"), name.hasSuffix(".upload") else { return nil }
		let stem = String(name.dropFirst(".talkward-".count).dropLast(".upload".count))
		guard stem.count > 37, stem.dropLast(36).hasSuffix("-"), canonicalUUID(String(stem.suffix(36))) != nil,
			let timestamp = Int64(stem.dropLast(37)), timestamp > 0 else { return nil }
		return Date(timeIntervalSince1970: Double(timestamp) / 1_000)
	}

	func loadConfiguration() async -> ConfigurationRead {
		guard let url = documentsURL()?.appendingPathComponent("config.json") else {
			return .unavailable("iCloud Drive is unavailable. Configuration restoration remains pending.")
		}
		do {
			let present = try await provider.discover(url)
			let provider = provider
			if let unavailable = try Self.configurationAvailability(at: url, provider: provider) { return unavailable }
			let read: ConfigurationRead
			do {
				read = try await coordinated(.read, at: url) { url, check in
					try check()
					return try Self.readConfiguration(at: url, provider: provider)
				}
			} catch where Self.isMissing(error) {
				read = .missing
			}
			if present, case .missing = read {
				return .unavailable("The iCloud configuration is waiting to download.")
			}
			return read
		} catch {
			return .unavailable("The iCloud configuration could not be checked. Restoration remains pending.")
		}
	}

	nonisolated private static func readConfiguration(at url: URL, provider: CloudProvider) throws -> ConfigurationRead {
		do {
			if let unavailable = try configurationAvailability(at: url, provider: provider) { return unavailable }
			guard try indexedFile(at: url).signature != nil else { throw MirrorError.invalidFile }
			return .decode(try Data(contentsOf: url))
		} catch where isMissing(error) { return .missing }
	}

	nonisolated private static func configurationAvailability(at url: URL, provider: CloudProvider) throws -> ConfigurationRead? {
		do {
			switch try provider.state(url) {
			case .current: return nil
			case .conflict: return .conflict
			case .notDownloaded, .stale, .downloading:
				try provider.requestDownload(url)
				return .unavailable("The iCloud configuration is waiting for its current version to download.")
			}
		} catch where isMissing(error) { return nil }
	}

	#if DEBUG
	func sync(entries: [JournalEntry], recordingsURL: URL, configuration: AppConfiguration,
		deletedRecordingReferences: Set<String>, revision: Int) async -> ICloudMirrorResult {
		guard let data = try? configuration.jsonData() else {
			var result = ICloudMirrorResult()
			result.failures = ["The configuration could not be encoded."]
			return result
		}
		return await sync(jobs: entries.map {
			CloudNoteJob(id: $0.id, contentRevision: revision, entry: $0, deletionReferences: [], audioReceipt: nil)
		}, recordingsURL: recordingsURL,
			configuration: CloudConfigurationJob(value: configuration, data: data, fingerprint: "fixture", mode: .replace),
			deletedRecordingReferences: deletedRecordingReferences, revision: revision)
	}
	#endif

	private func documentsURL() -> URL? {
		if let containerURL {
			return containerURL.appendingPathComponent("Documents", isDirectory: true)
		}
		return fileManager
			.url(forUbiquityContainerIdentifier: Self.containerIdentifier)?
			.appendingPathComponent("Documents", isDirectory: true)
	}


	private func exportStem(for entry: JournalEntry) -> String {
		let components = Calendar.current.dateComponents([.year, .month, .day], from: entry.createdAt)
		let date = String(
			format: "%04d-%02d-%02d",
			components.year ?? 0,
			components.month ?? 0,
			components.day ?? 0
		)
		return "\(date)_\(cityComponent(for: entry))__\(entry.id.uuidString)"
	}

	private func cityComponent(for entry: JournalEntry) -> String {
		let city = entry.location?.city?.trimmingCharacters(in: .whitespacesAndNewlines)
		guard let city, !city.isEmpty else { return "Unknown" }
		let invalidCharacters = CharacterSet(charactersIn: "/\\:?*\"<>|")
			.union(.controlCharacters)
			.union(.newlines)
		let sanitized = city.unicodeScalars.map {
			invalidCharacters.contains($0) ? "-" : String($0)
		}.joined()
		let collapsed = sanitized.replacingOccurrences(
			of: "-+",
			with: "-",
			options: .regularExpression
		)
		let trimmed = collapsed.trimmingCharacters(in: CharacterSet(charactersIn: " .-"))
		return trimmed.isEmpty ? "Unknown" : String(trimmed.prefix(48))
	}


}
