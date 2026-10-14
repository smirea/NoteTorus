import SwiftUI
import UIKit

struct SettingsView: View {
	@Environment(\.dismiss) private var dismiss
	@Environment(\.openURL) private var openURL
	@Bindable var store: JournalStore
	@State private var showsClearConfirmation = false
	@State private var showsCalendarAccessAlert = false
	@State private var isRequestingCalendarAccess = false

	init(store: JournalStore) {
		self.store = store
	}

	var body: some View {
		NavigationStack {
			ScrollViewReader { proxy in
				List {
					Section {
						sectionHeading("Recording")
						Toggle("Keep screen awake", isOn: settingBinding(\.keepScreenAwakeWhileRecording))
						Toggle("Haptics", isOn: settingBinding(\.hapticsEnabled))
					}
					.listRowBackground(AppStyle.background)

					Section {
						sectionHeading("Journal")
						Toggle("Show transcripts", isOn: settingBinding(\.showTranscripts))
					}
					.listRowBackground(AppStyle.background)

					Section {
						sectionHeading("Transcription")
						Toggle(
							"Prefer ElevenLabs transcription",
							isOn: settingBinding(\.preferElevenLabsTranscription)
						)
						LabeledContent("API key") {
							SecureField("Optional", text: elevenLabsAPIKeyBinding)
								.multilineTextAlignment(.trailing)
								.textInputAutocapitalization(.never)
								.autocorrectionDisabled()
								.textContentType(.password)
								.privacySensitive()
						}
					}
					.listRowBackground(AppStyle.background)

					calendarSection.id("calendar-settings")

					Section {
						sectionHeading("Data")
						if store.cloudStatusMessage != nil {
							Button("Try Again") { store.retryCloudSync() }
								.disabled(store.isCloudSyncing || store.isCapturePriorityActive)
						}
						Button("Delete all entries", role: .destructive) {
							showsClearConfirmation = true
						}
						.disabled(store.entries.isEmpty || store.isDemoMode)
					} footer: {
						if let message = store.cloudStatusMessage { Text(message) }
					}
					.id("cloud-settings")
					.listRowBackground(AppStyle.background)
				}
				.listStyle(.plain)
				.scrollContentBackground(.hidden)
				.background(AppStyle.background)
				.navigationTitle("Settings")
				.toolbar {
					ToolbarItem(placement: .confirmationAction) {
						Button("Done") { dismiss() }
					}
				}
				.task {
					#if DEBUG
					if ProcessInfo.processInfo.arguments.contains("-demo-settings-calendar") {
						await Task.yield()
						proxy.scrollTo("calendar-settings", anchor: .top)
					} else if ProcessInfo.processInfo.arguments.contains("-demo-cloud-pending")
						|| ProcessInfo.processInfo.arguments.contains("-demo-configuration-damaged") {
						await Task.yield()
						proxy.scrollTo("cloud-settings", anchor: .center)
					}
					#endif
				}
			}
		}
		.preferredColorScheme(.dark)
		.presentationBackground(AppStyle.background)
		.alert("Delete the journal?", isPresented: $showsClearConfirmation) {
			Button("Cancel", role: .cancel) {}
			Button("Delete all", role: .destructive) { Task { await store.clearJournal() } }
		} message: {
			Text("This permanently deletes every note, recording, and iCloud Drive export.")
		}
		.alert("Journal storage", isPresented: Binding(
			get: { store.storageErrorMessage != nil },
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
		.alert("Calendar access is off", isPresented: $showsCalendarAccessAlert) {
			Button("Not now", role: .cancel) {}
			Button("Open Settings") {
				if let url = URL(string: UIApplication.openSettingsURLString) {
					openURL(url)
				}
			}
		} message: {
			Text("Allow Calendar access in Settings to attach events to recordings.")
		}
	}

	private var calendarSection: some View {
		Section {
			sectionHeading("Calendar")
			Toggle("Calendar sync", isOn: calendarSyncBinding)
				.disabled(isRequestingCalendarAccess)

			if store.settings.calendarSyncEnabled {
				Picker("Preferred calendar", selection: settingBinding(\.preferredCalendarApp)) {
					ForEach(PreferredCalendarApp.allCases) { app in
						Text(app.title).tag(app)
					}
				}

				ForEach(store.calendarSync.calendars) { calendar in
					CalendarSettingRow(
						calendar: calendar,
						isIncluded: calendarBinding(for: calendar)
					)
				}
			}
		}
		.listRowBackground(AppStyle.background)
	}

	private func sectionHeading(_ title: String) -> some View {
		Text(title)
			.font(.subheadline.weight(.semibold))
			.foregroundStyle(AppStyle.secondary)
			.padding(.top, 12)
			.padding(.bottom, 4)
			.accessibilityAddTraits(.isHeader)
			.listRowSeparator(.hidden)
	}

	private func settingBinding<Value>(_ keyPath: WritableKeyPath<JournalSettings, Value>) -> Binding<Value> {
		Binding(get: { store.settings[keyPath: keyPath] }, set: { store.updateSetting(keyPath, $0) })
	}

	private var calendarSyncBinding: Binding<Bool> {
		Binding(
			get: { store.settings.calendarSyncEnabled },
			set: { enabled in
				if !enabled {
					store.updateSetting(\.calendarSyncEnabled, false)
					return
				}
				isRequestingCalendarAccess = true
				Task {
					let granted = await store.requestCalendarAccess()
					store.updateSetting(\.calendarSyncEnabled, granted)
					isRequestingCalendarAccess = false
					if !granted {
						showsCalendarAccessAlert = true
					}
				}
			}
		)
	}

	private var elevenLabsAPIKeyBinding: Binding<String> {
		Binding(
			get: { store.elevenLabsAPIKey },
			set: { store.setElevenLabsAPIKey($0) }
		)
	}

	private func calendarBinding(for calendar: CalendarSource) -> Binding<Bool> {
		Binding(
			get: {
				store.settings.includedCalendarIdentifiers?.contains(calendar.id) ?? true
			},
			set: { isIncluded in
				var identifiers = store.settings.includedCalendarIdentifiers
					?? Set(store.calendarSync.calendars.map(\.id))
				if isIncluded {
					identifiers.insert(calendar.id)
				} else {
					identifiers.remove(calendar.id)
				}
				store.updateSetting(\.includedCalendarIdentifiers, identifiers)
			}
		)
	}
}

private struct CalendarSettingRow: View {
	let calendar: CalendarSource
	@Binding var isIncluded: Bool

	var body: some View {
		Toggle(isOn: $isIncluded) {
			VStack(alignment: .leading, spacing: 2) {
				Text(calendar.title)
				Text(calendar.sourceTitle)
					.font(.caption)
					.foregroundStyle(.secondary)
			}
		}
	}
}
