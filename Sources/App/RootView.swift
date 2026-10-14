import SwiftUI

enum AppDeepLink: Equatable, Sendable {
	case record
	case entry(UUID)
	case recording(UUID?)

	init?(url: URL) {
		guard url.scheme?.lowercased() == "myvoicememo" else { return nil }
		let ids = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.filter { $0.name == "id" } ?? []
		let id = ids.count == 1 ? ids.first?.value.flatMap(UUID.init(uuidString:)) : nil
		switch url.host?.lowercased() {
		case "record": self = .record
		case "entry":
			guard let id else { return nil }
			self = .entry(id)
		case "recording": self = .recording(id)
		default: return nil
		}
	}
}

private enum AppRoute: Hashable {
	case entry(UUID)
	case review
}

struct RootView: View {
	@Environment(\.scenePhase) private var scenePhase
	@Bindable var store: JournalStore
	@Bindable var recordingSession: RecordingSession
	@State private var path: [AppRoute] = []
	@State private var showsSettings = false
	@State private var linkGeneration = UUID()

	init(store: JournalStore, recordingSession: RecordingSession) {
		self.store = store
		self.recordingSession = recordingSession
		let arguments = ProcessInfo.processInfo.arguments
		if arguments.contains("-demo-entry"), let entry = store.entries.first(where: { Calendar.current.component(.day, from: $0.createdAt) == 11 }) {
			_path = State(initialValue: [.entry(entry.id)])
		}
		if arguments.contains("-demo-tasks"), let entry = store.entries.first(where: { !$0.tasks.isEmpty }) {
			_path = State(initialValue: [.entry(entry.id)])
		}
		if arguments.contains("-demo-review") {
			_path = State(initialValue: [.review])
		}
		if arguments.contains("-demo-settings") {
			_showsSettings = State(initialValue: true)
		}
	}

	var body: some View {
		NavigationStack(path: $path) {
			JournalView(
				store: store,
				onSelectEntry: { path.append(.entry($0.id)) },
				onNewRecording: { recordingSession.present(startsImmediately: false) },
				onReview: { path.append(.review) },
				onSettings: { showsSettings = true }
			)
			.toolbar(.hidden, for: .navigationBar)
			.navigationDestination(for: AppRoute.self) { route in
				switch route {
				case let .entry(entryID):
					if let entry = store.entry(id: entryID) {
						EntryView(store: store, entry: entry)
					}
				case .review:
					ReviewView(store: store, date: .now)
				}
			}
		}
		.background(AppStyle.background)
		.fullScreenCover(item: Binding(
			get: { recordingSession.context },
			// Only finishing or explicitly discarding may dismiss an owned recording session.
			set: { _ in }
		)) { _ in
			RecordView(
				store: store,
				session: recordingSession,
				onClose: { path.removeAll() },
				onFinished: { entryID in
					path = [.entry(entryID)]
				}
			)
		}
		.sheet(isPresented: $showsSettings) {
			SettingsView(store: store)
		}
		.alert("ElevenLabs wasn’t used", isPresented: Binding(
			get: { store.transcriptionAlertMessage != nil },
			set: { if !$0 { store.clearTranscriptionAlert() } }
		)) {
			Button("OK", role: .cancel) { store.clearTranscriptionAlert() }
		} message: {
			Text(store.transcriptionAlertMessage ?? "")
		}
		.alert("ProcrastiMate", isPresented: Binding(
			get: { recordingSession.context == nil && store.procrastiMateMessage != nil },
			set: { if !$0 { store.procrastiMateMessage = nil } }
		)) {
			Button("OK", role: .cancel) { store.procrastiMateMessage = nil }
		} message: {
			Text(store.procrastiMateMessage ?? "")
		}
		.alert("Journal storage", isPresented: Binding(
			get: { !showsSettings && recordingSession.context == nil && store.storageErrorMessage != nil },
			set: { if !$0 { store.storageErrorMessage = nil } }
		)) {
			if store.hasUnsavedNoteChanges {
				Button("Try Saving Again") {
					store.storageErrorMessage = nil
					Task { await store.retrySavingChanges() }
				}
			}
			Button("OK", role: .cancel) { store.storageErrorMessage = nil }
		} message: {
			Text(store.storageErrorMessage ?? "")
		}
		.onOpenURL { url in
			guard let link = AppDeepLink(url: url), recordingSession.context == nil else { return }
			let generation = UUID()
			linkGeneration = generation
			switch link {
			case .record:
				path.removeAll()
				recordingSession.present(startsImmediately: true)
			case let .entry(id):
				openSavedEntry(id, generation: generation)
			case let .recording(id):
				showsSettings = false
				path.removeAll()
				if let id { openSavedEntry(id, generation: generation) }
			}
		}
		.task {
			if recordingSession.isVisualDemo {
				recordingSession.present(startsImmediately: true)
			}
			#if DEBUG
			if store.isDemoMode, ProcessInfo.processInfo.arguments.contains("-demo-storage-error") {
				try? await Task.sleep(for: .milliseconds(600))
				store.storageErrorMessage = "Couldn’t delete one note. Its audio is still on this device. Try deleting it again."
			}
			#endif
			await store.refreshCalendar()
			#if DEBUG
			if store.isDemoMode, ProcessInfo.processInfo.arguments.contains("-demo-calendar-occurrences") {
				recordingSession.present(startsImmediately: false)
			}
			#endif
		}
		.onReceive(NotificationCenter.default.publisher(for: .NSUbiquityIdentityDidChange)) { _ in
			store.retryCloudSync()
		}
		.onChange(of: scenePhase) { _, phase in
			guard phase == .active else { return }
			store.resumeStaleProcessing()
			Task { await store.refreshCalendar() }
		}
	}
	private func openSavedEntry(_ id: UUID, generation: UUID) {
		Task {
			if !store.isDemoMode { try? await store.waitUntilLoaded() }
			guard linkGeneration == generation, recordingSession.context == nil, store.entry(id: id) != nil else { return }
			path = [.entry(id)]
		}
	}

}
