#if DEBUG
import Foundation

enum CalendarOccurrenceContractChecks {
	static func runFromLaunchArguments() async {
		guard ProcessInfo.processInfo.arguments.contains("-calendar-occurrence-contract-tests") else { return }
		do {
			try recurringIdentity()
			try legacyIdentity()
			try keysAndDecoding()
			try queryWindowsAndDST()
			print("CALENDAR OCCURRENCE CONTRACT: exact recurrence, calendar boundaries, ambiguity, legacy adoption, stable keys, Codable compatibility, and bounded DST queries passed")
			fflush(stdout)
		} catch { fatalError("CALENDAR OCCURRENCE CONTRACT: \(error)") }
	}

	private static let date = Date(timeIntervalSince1970: 1_900_000_000)

	private static func recurringIdentity() throws {
		let saved = event(id: "requested", start: date)
		let seriesHead = event(id: "head", start: date.addingTimeInterval(-604_800))
		var moved = saved
		moved.id = "detached"
		moved.title = "Renamed occurrence"
		moved.startDate.addTimeInterval(86_400 * 60)
		moved.endDate.addTimeInterval(86_400 * 60)
		try expect(CalendarOccurrenceIdentity.match(for: saved, among: [seriesHead, moved]) == .matched(moved),
			"A direct series-head lookup must not replace the requested detached occurrence")
		try expect(CalendarOccurrenceIdentity.match(for: saved, among: [seriesHead]) == .missing,
			"Matching series IDs with the wrong original date must remain missing")
		var unproven = moved
		unproven.occurrenceDate = nil
		try expect(CalendarOccurrenceIdentity.uniqueMatch(for: saved, among: [unproven]) == nil,
			"A changed start without original-date proof must not become the saved occurrence")
		var wrongCalendar = moved
		wrongCalendar.calendarIdentifier = "another-account"
		try expect(CalendarOccurrenceIdentity.match(for: saved, among: [wrongCalendar]) == .missing,
			"Equal external IDs and calendar titles cannot cross a known calendar boundary")
		var conflicting = saved
		conflicting.externalIdentifier = "different-series"
		try expect(CalendarOccurrenceIdentity.match(for: saved, among: [conflicting]) == .missing,
			"Conflicting known external IDs cannot be overridden by local ID or title equality")
		var copy = moved
		copy.id = "another-native-item"
		copy.localIdentifier = "another-local-item"
		try expect(CalendarOccurrenceIdentity.match(for: saved, among: [moved, copy]) == .ambiguous,
			"Distinct native items sharing external/original identity must stay ambiguous")
		try expect(CalendarOccurrenceIdentity.match(for: saved, among: [moved, moved]) == .matched(moved),
			"The literal same snapshot returned by two lookup routes must not create false ambiguity")
		var inconsistentSnapshot = moved
		inconsistentSnapshot.notes = "A different snapshot arrived during lookup"
		try expect(CalendarOccurrenceIdentity.match(for: saved, among: [moved, inconsistentSnapshot]) == .ambiguous,
			"Conflicting snapshots must not be resolved by lookup order")
	}

	private static func legacyIdentity() throws {
		var saved = event(id: "legacy", start: date)
		saved.occurrenceDate = nil
		var moved = saved
		moved.occurrenceDate = saved.startDate
		moved.startDate.addTimeInterval(86_400)
		moved.endDate.addTimeInterval(86_400)
		try expect(CalendarOccurrenceIdentity.uniqueMatch(for: saved, among: [moved]) == moved,
			"An originally unmodified legacy occurrence may adopt exact original-date proof after moving")
		var previouslyMoved = saved
		previouslyMoved.occurrenceDate = date.addingTimeInterval(-86_400)
		try expect(CalendarOccurrenceIdentity.uniqueMatch(for: saved, among: [previouslyMoved]) == previouslyMoved,
			"A uniquely identified legacy snapshot may adopt original identity while its saved current start still matches")
		saved.id = "obsolete-native-id"
		saved.localIdentifier = nil
		saved.externalIdentifier = nil
		saved.title = "CAFÉ — DESIGN"
		var current = event(id: "new-native-id", start: date)
		current.localIdentifier = "new-local-id"
		current.title = "cafe design"
		try expect(CalendarOccurrenceIdentity.uniqueMatch(for: saved, among: [current]) == current,
			"Legacy fallback requires one same-calendar normalized exact title and exact saved start")
		try expect(CalendarOccurrenceIdentity.normalizedTitle("ISTANBUL — CAFÉ") == "istanbul cafe",
			"Exact-title normalization must use a fixed locale rather than the user's current locale")
		var nearby = current
		nearby.startDate.addTimeInterval(1)
		try expect(CalendarOccurrenceIdentity.match(for: saved, among: [nearby]) == .missing,
			"A nearby title match cannot replace an exact occurrence")
		var conflictingDate = current
		conflictingDate.occurrenceDate = date.addingTimeInterval(-86_400)
		try expect(CalendarOccurrenceIdentity.match(for: saved, among: [conflictingDate]) == .missing,
			"Title fallback cannot override conflicting original-date evidence")
		var duplicate = current
		duplicate.id = "another-native-id"
		duplicate.localIdentifier = "another-local-id"
		try expect(CalendarOccurrenceIdentity.match(for: saved, among: [current, duplicate]) == .ambiguous,
			"Legacy fallback must not choose between two credible native candidates")
		saved.calendarIdentifier = ""
		try expect(CalendarOccurrenceIdentity.match(for: saved, among: [current]) == .missing,
			"An unknown calendar must never widen exact occurrence selection")
	}

	private static func keysAndDecoding() throws {
		let saved = event(id: "original", start: date.addingTimeInterval(0.1234))
		var moved = saved
		moved.id = "detached-id"
		moved.startDate.addTimeInterval(604_800)
		try expect(saved.focusKey == moved.focusKey, "Current date/identifier changes must preserve a proven external-series/original occurrence key")
		var anotherCalendar = saved
		anotherCalendar.calendarIdentifier = "another-calendar"
		try expect(saved.focusKey != anotherCalendar.focusKey, "Identical series and original dates in different calendars need different keys")
		var next = saved
		next.occurrenceDate = saved.occurrenceDate!.addingTimeInterval(0.001)
		try expect(saved.focusKey != next.focusKey, "Exact occurrence keys must not truncate distinct dates to integer seconds")
		var legacy = saved
		legacy.occurrenceDate = nil
		try expect(legacy.focusKey == moved.focusKey, "Adopting the saved start as proven original identity should preserve the occurrence key")
		var ambiguousComponents = saved
		ambiguousComponents.calendarIdentifier = "a"
		ambiguousComponents.externalIdentifier = "bc"
		var differentComponents = ambiguousComponents
		differentComponents.calendarIdentifier = "ab"
		differentComponents.externalIdentifier = "c"
		try expect(ambiguousComponents.focusKey != differentComponents.focusKey, "Component encoding must not admit concatenation collisions")
		let encoded = try JSONEncoder().encode(saved)
		let decoded = try JSONDecoder().decode(JournalCalendarEvent.self, from: encoded)
		try expect(decoded == saved, "Current/original dates must survive the persisted and exported value model")
		var oldObject = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
		oldObject.removeValue(forKey: "occurrenceDate")
		let old = try JSONDecoder().decode(JournalCalendarEvent.self, from: JSONSerialization.data(withJSONObject: oldObject))
		try expect(old.occurrenceDate == nil && old.startDate == saved.startDate,
			"Old JSON must retain a missing original date rather than inventing one")
	}

	private static func queryWindowsAndDST() throws {
		var utc = Calendar(identifier: .gregorian)
		utc.timeZone = TimeZone(secondsFromGMT: 0)!
		var moved = event(id: "windows", start: date)
		moved.startDate.addTimeInterval(86_400 * 60)
		let windows = CalendarOccurrenceIdentity.queryWindows(for: moved, calendar: utc)
		try expect(windows.count == 2 && windows.allSatisfy { $0.upperBound.timeIntervalSince($0.lowerBound) == 259_200 }
			&& windows[1].upperBound < windows[0].lowerBound,
			"Far moved occurrences need two bounded windows rather than scanning the intervening history")
		moved.occurrenceDate = moved.startDate.addingTimeInterval(60)
		try expect(CalendarOccurrenceIdentity.queryWindows(for: moved, calendar: utc).count == 1, "Anchors on the same civil day need only one native range query")
		moved.calendarIdentifier = ""
		try expect(CalendarOccurrenceIdentity.queryWindows(for: moved, calendar: utc).isEmpty, "Unknown calendar identity must produce no all-calendar query plan")
		moved.calendarIdentifier = "calendar"
		moved.startDate = Date(timeIntervalSince1970: .nan)
		try expect(CalendarOccurrenceIdentity.queryWindows(for: moved, calendar: utc).isEmpty, "Invalid source dates must not enter native date arithmetic")
		var local = Calendar(identifier: .gregorian)
		local.timeZone = TimeZone(identifier: "America/New_York")!
		for (month, day, hours) in [(3, 8, 71.0), (11, 1, 73.0)] {
			let original = local.date(from: DateComponents(year: 2026, month: month, day: day))!
			var allDay = event(id: "all-day", start: original)
			allDay.isAllDay = true
			let windows = CalendarOccurrenceIdentity.queryWindows(for: allDay, calendar: local)
			try expect(windows.count == 1 && windows[0].upperBound.timeIntervalSince(windows[0].lowerBound) == hours * 3_600,
				"Civil query days must follow daylight-saving boundaries instead of adding fixed 24-hour spans")
			var changedZone = allDay
			changedZone.occurrenceDate = original.addingTimeInterval(3_600)
			changedZone.startDate.addTimeInterval(3_600)
			try expect(CalendarOccurrenceIdentity.match(for: allDay, among: [changedZone]) == .missing,
				"A floating/all-day timezone shift without matching original Date proof must fail conservatively, not use a broad day tolerance")
		}
	}

	private static func event(id: String, start: Date) -> JournalCalendarEvent {
		JournalCalendarEvent(id: id, localIdentifier: "series-local", externalIdentifier: "series-external",
			calendarIdentifier: "calendar", calendarTitle: "Work", title: "Team Review", startDate: start,
			endDate: start.addingTimeInterval(1_800), isAllDay: false, isRecurring: true, occurrenceDate: start)
	}
	private static func expect(_ condition: Bool, _ message: String) throws { if !condition { throw Failure(message) } }
	private struct Failure: Error, CustomStringConvertible {
		var description: String
		init(_ description: String) { self.description = description }
	}
}
#endif
