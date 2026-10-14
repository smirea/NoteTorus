import Foundation

enum CalendarOccurrenceIdentity {
	enum Match: Equatable, Sendable {
		case matched(JournalCalendarEvent)
		case missing
		case ambiguous
	}

	static func uniqueMatch(for stored: JournalCalendarEvent, among candidates: [JournalCalendarEvent]) -> JournalCalendarEvent? {
		guard case let .matched(event) = match(for: stored, among: candidates) else { return nil }
		return event
	}

	static func match(for stored: JournalCalendarEvent, among candidates: [JournalCalendarEvent]) -> Match {
		guard identifier(stored.calendarIdentifier) != nil, validDate(stored.startDate),
			stored.occurrenceDate.map(validDate) ?? true else { return .missing }
		let scoped = Array(Set(candidates)).filter {
			$0.calendarIdentifier == stored.calendarIdentifier && validDate($0.startDate)
				&& ($0.occurrenceDate.map(validDate) ?? true) && !conflictingExternalIDs(stored, $0)
		}
		let identified = scoped.filter { compatibleIdentity(stored, $0) }
		let exact = identified.filter { compatibleDate(stored, $0) }
		if !exact.isEmpty { return result(exact) }
		guard stored.occurrenceDate == nil, identified.isEmpty, !normalizedTitle(stored.title).isEmpty else { return .missing }
		let legacy = scoped.filter {
			normalizedTitle($0.title) == normalizedTitle(stored.title) && $0.startDate == stored.startDate
				&& ($0.occurrenceDate == nil || $0.occurrenceDate == stored.startDate)
		}
		return result(legacy)
	}

	static func focusKey(for event: JournalCalendarEvent) -> String {
		let kind: String
		let value: String
		if let external = identifier(event.externalIdentifier) { kind = "external"; value = external }
		else if let local = identifier(event.localIdentifier) { kind = "local"; value = local }
		else { kind = "native"; value = event.id }
		let interval = (event.occurrenceDate ?? event.startDate).timeIntervalSinceReferenceDate
		let bits = interval == 0 ? Double.zero.bitPattern : interval.bitPattern
		return ["occurrence-v1", event.calendarIdentifier, kind, value, String(bits, radix: 16)]
			.map { "\($0.utf8.count):\($0)" }.joined()
	}

	static func queryWindows(for event: JournalCalendarEvent, calendar: Calendar = .current) -> [Range<Date>] {
		guard identifier(event.calendarIdentifier) != nil, validDate(event.startDate),
			event.occurrenceDate.map(validDate) ?? true else { return [] }
		var windows: [Range<Date>] = []
		for date in [event.startDate, event.occurrenceDate].compactMap({ $0 }) where validDate(date) {
			let day = calendar.startOfDay(for: date)
			guard let lower = calendar.date(byAdding: .day, value: -1, to: day),
				let upper = calendar.date(byAdding: .day, value: 2, to: day), lower < upper else { continue }
			let window = lower..<upper
			if !windows.contains(window) { windows.append(window) }
		}
		return windows
	}

	static func normalizedTitle(_ title: String) -> String {
		title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
			.unicodeScalars
			.map { CharacterSet.alphanumerics.contains($0) ? String($0) : " " }
			.joined()
			.split(whereSeparator: \.isWhitespace)
			.joined(separator: " ")
	}

	private static func result(_ candidates: [JournalCalendarEvent]) -> Match {
		if candidates.count == 1 { return .matched(candidates[0]) }
		return candidates.isEmpty ? .missing : .ambiguous
	}

	private static func compatibleIdentity(_ stored: JournalCalendarEvent, _ candidate: JournalCalendarEvent) -> Bool {
		if let external = identifier(stored.externalIdentifier), external == identifier(candidate.externalIdentifier) { return true }
		let storedIDs = Set([stored.id, stored.localIdentifier].compactMap(identifier))
		let candidateIDs = Set([candidate.id, candidate.localIdentifier].compactMap(identifier))
		return !storedIDs.isDisjoint(with: candidateIDs)
	}

	private static func conflictingExternalIDs(_ stored: JournalCalendarEvent, _ candidate: JournalCalendarEvent) -> Bool {
		guard let storedID = identifier(stored.externalIdentifier), let candidateID = identifier(candidate.externalIdentifier) else { return false }
		return storedID != candidateID
	}

	private static func compatibleDate(_ stored: JournalCalendarEvent, _ candidate: JournalCalendarEvent) -> Bool {
		if let original = stored.occurrenceDate { return candidate.occurrenceDate == original }
		return candidate.startDate == stored.startDate || candidate.occurrenceDate == stored.startDate
	}

	private static func identifier(_ value: String?) -> String? {
		guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
		return value
	}

	private static func validDate(_ value: Date) -> Bool {
		value.timeIntervalSinceReferenceDate.isFinite && value >= .distantPast && value <= .distantFuture
	}
}

extension JournalCalendarEvent {
	var focusKey: String {
		CalendarOccurrenceIdentity.focusKey(for: self)
	}
}
