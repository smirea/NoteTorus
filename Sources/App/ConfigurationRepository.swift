import CryptoKit
import Foundation

actor ConfigurationRepository {
	private struct Provisional: Codable {
		var schemaVersion = 1
		var baseline: AppConfiguration
		var current: AppConfiguration
		var keyEdited = false
	}
	private struct CloudState: Codable {
		var schemaVersion = 1
		var exportedFingerprint: String?
		var failureFingerprint: String?
		var retry: CloudRetryState?
	}
	private let rootURL: URL
	private var value = AppConfiguration(settings: JournalSettings())
	private var status = ConfigurationSnapshot.Status.blocked
	private var provisional: Provisional?
	private var canonicalData: Data?
	private var provisionalData: Data?
	private var cloud = CloudState()
	private var revision = 0
	private var confirmedMissing = false
	private var issue: String?
	private var loaded = false
	private var canonicalURL: URL { rootURL.appendingPathComponent("config.json") }
	private var provisionalURL: URL { rootURL.appendingPathComponent("config-pending.json") }
	private var cloudURL: URL { rootURL.appendingPathComponent("config-cloud.json") }

	init(rootURL: URL) { self.rootURL = rootURL }

	func load(baseline: AppConfiguration) throws -> ConfigurationSnapshot {
		guard !loaded || status == .blocked else { return snapshot() }
		status = .blocked
		canonicalData = nil
		provisionalData = nil
		provisional = nil
		cloud = CloudState()
		confirmedMissing = false
		issue = nil
		try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
		value = baseline
		do {
			if let data = try read(canonicalURL) {
				switch ConfigurationRead.decode(data) {
				case .available(let configuration):
					value = configuration
					canonicalData = data
					status = .ready
					try? FileManager.default.removeItem(at: provisionalURL)
				case .unsupported: issue = "The saved configuration was created by a newer app. Its original file was preserved."
				default: issue = "The saved configuration is damaged. Its original file was preserved."
				}
			} else if let data = try read(provisionalURL) {
				let pending = try JSONDecoder().decode(Provisional.self, from: data)
				guard pending.schemaVersion == 1 else { throw ConfigurationStorageError.blocked }
				provisional = pending
				provisionalData = data
				value = pending.current
				status = .provisional
			} else {
				let pending = Provisional(baseline: baseline, current: baseline)
				provisionalData = try write(pending, to: provisionalURL)
				provisional = pending
				status = .provisional
			}
		} catch {
			status = .blocked
			issue = "The saved configuration could not be opened. Its original files were preserved."
		}
		do {
			if let data = try read(cloudURL) {
				let state = try JSONDecoder().decode(CloudState.self, from: data)
				guard state.schemaVersion == 1 else { throw ConfigurationStorageError.blocked }
				cloud = state
			}
		} catch { issue = issue ?? "Configuration export status could not be read. Export will be checked again." }
		loaded = true
		revision += 1
		return snapshot()
	}

	func snapshot(repair: Bool = false, now: Date = .now) -> ConfigurationSnapshot {
		let fingerprint = canonicalData.map(Self.fingerprint)
		let retry = cloud.failureFingerprint == sourceFingerprint ? cloud.retry : nil
		let due = repair || (retry?.isDue(at: now) ?? true)
		var job: CloudConfigurationJob?
		if status == .ready, let data = canonicalData, let fingerprint,
			due && (repair || cloud.exportedFingerprint != fingerprint) {
			job = CloudConfigurationJob(value: value, data: data, fingerprint: fingerprint, mode: .replace)
		} else if status == .provisional, confirmedMissing, due, let data = try? value.jsonData() {
			job = CloudConfigurationJob(value: value, data: data, fingerprint: Self.fingerprint(data), mode: .createIfMissing)
		}
		let pending = status == .provisional || (status == .ready && cloud.exportedFingerprint != fingerprint)
		return ConfigurationSnapshot(value: value, revision: revision, status: status, export: job,
			needsRestore: status == .provisional && !confirmedMissing && due,
			issue: issue ?? retry?.message,
			nextRetry: pending ? (retry == nil ? .distantPast : retry?.retryAfter) : nil)
	}

	func saveLocal(_ proposed: AppConfiguration, baseline: AppConfiguration? = nil, keyEdited: Bool = false) throws -> ConfigurationSnapshot {
		guard loaded, status != .blocked else { throw ConfigurationStorageError.blocked }
		let updated = baseline.map { Self.merge(proposed, baseline: $0, into: value, keyEdited: keyEdited) } ?? proposed
		if status == .provisional, var pending = provisional {
			pending.current = updated
			pending.keyEdited = pending.keyEdited || keyEdited
			provisionalData = try write(pending, to: provisionalURL)
			provisional = pending
			value = updated
		} else {
			try saveCanonical(updated)
		}
		cloud.retry = nil
		cloud.failureFingerprint = nil
		issue = nil
		revision += 1
		return snapshot()
	}

	func applyRemote(_ result: ConfigurationRead, expectedRevision: Int? = nil, now: Date = .now) throws -> ConfigurationSnapshot {
		guard status == .provisional, let pending = provisional else { return snapshot(now: now) }
		switch result {
		case .available(let remote):
			let merged = Self.merge(pending.current, baseline: pending.baseline, into: remote, keyEdited: pending.keyEdited)
			try saveCanonical(merged)
			status = .ready
			provisional = nil
			confirmedMissing = false
			try? FileManager.default.removeItem(at: provisionalURL)
			cloud.retry = nil
			cloud.failureFingerprint = nil
			issue = nil
			revision += 1
		case .missing:
			guard expectedRevision == nil || expectedRevision == revision else { return snapshot(now: now) }
			confirmedMissing = true
			cloud.retry = nil
			issue = nil
			revision += 1
		case .unavailable(let message), .damaged(let message):
			return try failCloud(fingerprint: nil, revision: expectedRevision ?? revision, message: message, now: now)
		case .unsupported:
			return try failCloud(fingerprint: nil, revision: expectedRevision ?? revision,
				message: "The iCloud configuration was created by a newer app. Its original file was preserved.", now: now)
		case .conflict:
			return try failCloud(fingerprint: nil, revision: expectedRevision ?? revision,
				message: "iCloud has conflicting configuration versions. They were preserved for resolution.", now: now)
		}
		return snapshot(now: now)
	}

	func acknowledgeCloud(fingerprint: String) throws -> ConfigurationSnapshot {
		guard status == .ready, canonicalData.map(Self.fingerprint) == fingerprint else { return snapshot() }
		guard cloud.exportedFingerprint != fingerprint || cloud.retry != nil else { return snapshot() }
		var updated = cloud
		updated.exportedFingerprint = fingerprint
		updated.failureFingerprint = nil
		updated.retry = nil
		try write(updated, to: cloudURL)
		cloud = updated
		issue = nil
		revision += 1
		return snapshot()
	}

	func failCloud(fingerprint: String?, revision expectedRevision: Int, message: String, now: Date = .now) throws -> ConfigurationSnapshot {
		guard status != .blocked, expectedRevision == revision,
			fingerprint == canonicalData.map(Self.fingerprint) || status == .provisional
		else { return snapshot(now: now) }
		var updated = cloud
		updated.failureFingerprint = sourceFingerprint
		updated.retry = .failed(previous: cloud.failureFingerprint == updated.failureFingerprint ? cloud.retry : nil,
			message: message, now: now)
		if updated.exportedFingerprint == updated.failureFingerprint { updated.exportedFingerprint = nil }
		try write(updated, to: cloudURL)
		cloud = updated
		issue = nil
		revision += 1
		return snapshot(now: now)
	}

	private func saveCanonical(_ configuration: AppConfiguration) throws {
		var configuration = configuration
		configuration.schemaVersion = AppConfiguration.currentSchemaVersion
		let data = try configuration.jsonData()
		try writeData(data, to: canonicalURL)
		value = configuration
		canonicalData = data
	}

	@discardableResult
	private func write<T: Encodable>(_ value: T, to url: URL) throws -> Data {
		let data = try JSONEncoder().encode(value)
		try writeData(data, to: url)
		return data
	}

	private func writeData(_ data: Data, to url: URL) throws {
		try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
		var url = url
		var values = URLResourceValues()
		values.isExcludedFromBackup = false
		try? url.setResourceValues(values)
	}

	private func read(_ url: URL) throws -> Data? {
		do { return try Data(contentsOf: url) }
		catch {
			let error = error as NSError
			if error.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) { return nil }
			throw error
		}
	}

	private var sourceFingerprint: String? {
		if let canonicalData { return Self.fingerprint(canonicalData) }
		return provisionalData.map(Self.fingerprint)
	}

	private static func fingerprint(_ data: Data) -> String {
		SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
	}

	nonisolated static func merge(_ current: AppConfiguration, baseline: AppConfiguration, into remote: AppConfiguration, keyEdited: Bool) -> AppConfiguration {
		var merged = remote
		func apply<T: Equatable>(_ path: WritableKeyPath<JournalSettings, T>) {
			if current.settings[keyPath: path] != baseline.settings[keyPath: path] {
				merged.settings[keyPath: path] = current.settings[keyPath: path]
			}
		}
		apply(\.keepScreenAwakeWhileRecording)
		apply(\.hapticsEnabled)
		apply(\.showTranscripts)
		apply(\.showModelNames)
		apply(\.preferElevenLabsTranscription)
		apply(\.calendarSyncEnabled)
		apply(\.includedCalendarIdentifiers)
		apply(\.preferredCalendarApp)
		if keyEdited || current.elevenLabsAPIKey != baseline.elevenLabsAPIKey { merged.elevenLabsAPIKey = current.elevenLabsAPIKey }
		let old = Dictionary(baseline.locations.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
		let changed = Dictionary(current.locations.filter { old[$0.id] != $0 }.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
		let removed = Set(old.keys).subtracting(current.locations.map(\.id))
		merged.locations.removeAll { removed.contains($0.id) }
		for location in changed.values {
			if let index = merged.locations.firstIndex(where: { $0.id == location.id }) { merged.locations[index] = location }
			else { merged.locations.append(location) }
		}
		merged.schemaVersion = AppConfiguration.currentSchemaVersion
		return merged
	}
}

enum ConfigurationStorageError: LocalizedError {
	case blocked
	var errorDescription: String? { "Configuration changes could not be saved. Original files were preserved." }
}


extension AppConfiguration {
	func applying(value: AppConfiguration, baseline: AppConfiguration, keyEdited: Bool = false) -> AppConfiguration {
		ConfigurationRepository.merge(value, baseline: baseline, into: self, keyEdited: keyEdited)
	}
}
