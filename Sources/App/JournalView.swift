import SwiftUI

struct JournalView: View {
	@Bindable var store: JournalStore
	let onSelectEntry: (JournalEntry) -> Void
	let onNewRecording: () -> Void
	let onReview: () -> Void
	let onSettings: () -> Void

	@State private var entryPendingDeletion: JournalEntry?

	var body: some View {
		ZStack(alignment: .bottom) {
			AppStyle.background.ignoresSafeArea()

			List {
				header
					.padding(.horizontal, 20)
					.padding(.bottom, 20)
				.listRowInsets(EdgeInsets())
				.listRowBackground(AppStyle.background)
				.listRowSeparator(.hidden)

				if store.hasUnsavedNoteChanges {
					Button("Note changes not saved. Try Again") {
						Task { await store.retrySavingChanges() }
					}
					.font(.footnote)
					.foregroundStyle(AppStyle.accent)
					.listRowBackground(AppStyle.background)
					.listRowSeparator(.hidden)
				}
				if store.isLoading {
					ProgressView("Opening journal")
						.listRowBackground(AppStyle.background)
						.listRowSeparator(.hidden)
				}
				if let message = store.storageLoadMessage {
					Text(message)
						.font(.footnote)
						.foregroundStyle(.secondary)
						.listRowBackground(AppStyle.background)
						.listRowSeparator(.hidden)
				}
				if !store.isLoading && store.storageLoadMessage == nil && store.entries.isEmpty {
					emptyState
						.listRowInsets(EdgeInsets())
						.listRowBackground(AppStyle.background)
						.listRowSeparator(.hidden)
				} else {
					ForEach(store.entries) { entry in
						Button { onSelectEntry(entry) } label: {
							EntryCard(entry: entry, processingPhase: store.processingPhase(for: entry.id))
						}
						.buttonStyle(.plain)
						.listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 9, trailing: 20))
						.listRowBackground(AppStyle.background)
						.listRowSeparator(.hidden)
						.swipeActions(edge: .trailing, allowsFullSwipe: false) {
							Button {
								entryPendingDeletion = entry
							} label: {
								Label("Delete", systemImage: "trash.fill")
							}
							.tint(.red)
						}
					}
				}

				Color.clear
					.frame(height: 95)
					.listRowInsets(EdgeInsets())
					.listRowBackground(AppStyle.background)
					.listRowSeparator(.hidden)
			}
			.listStyle(.plain)
			.scrollContentBackground(.hidden)
			.scrollIndicators(.hidden)
			.environment(\.defaultMinListRowHeight, 0)

			HStack {
				Button(action: onReview) {
					Label("Review", systemImage: "calendar")
						.font(.system(size: 14, weight: .medium))
						.foregroundStyle(.white)
						.padding(.horizontal, 22)
						.frame(height: 50)
						.glassEffect(.regular.interactive(), in: Capsule())
				}
				.buttonStyle(.plain)
				.accessibilityHint("Opens this week's review")

				Spacer()

				Button(action: onNewRecording) {
					Label("Record", systemImage: "mic.fill")
						.font(.system(size: 14, weight: .medium))
						.foregroundStyle(.white)
						.padding(.horizontal, 25)
						.frame(height: 50)
						.background(AppStyle.accent, in: Capsule())
						.shadow(color: AppStyle.accent.opacity(0.34), radius: 18, y: 8)
				}
				.buttonStyle(.plain)
				.accessibilityHint("Starts a voice memo")
			}
			.padding(.horizontal, 20)
			.padding(.bottom, 18)
		}
		.modifier(MemoDeletionConfirmation(store: store, entry: $entryPendingDeletion))
	}

	private var header: some View {
		HStack {
			TimelineView(.periodic(from: .now, by: 60)) { context in
				Text(context.date.formatted(Date.FormatStyle.journalHeader))
					.font(.system(size: 32, weight: .regular))
					.foregroundStyle(.white)
			}

			Spacer()

			Button(action: onSettings) {
				Image(systemName: "gearshape")
					.font(.system(size: 17, weight: .regular))
					.foregroundStyle(Color.white.opacity(0.88))
					.frame(width: 44, height: 44)
					.glassEffect(.regular.interactive(), in: Circle())
			}
			.buttonStyle(.plain)
			.accessibilityLabel("Settings")
		}
		.padding(.top, 8)
	}

	private var emptyState: some View {
		VStack(spacing: 12) {
			Text("No voice memos")
				.font(.system(size: 21, weight: .medium))
			Text("Tap Record to record.")
				.font(.system(size: 15))
				.foregroundStyle(AppStyle.secondary)
				.multilineTextAlignment(.center)
				.frame(maxWidth: 270)
		}
		.frame(maxWidth: .infinity)
		.padding(.top, 112)
	}
}

private struct EntryCard: View {
	let entry: JournalEntry
	let processingPhase: EntryProcessingPhase?

	private var timestamp: String {
		let currentYear = Calendar.current.component(.year, from: .now)
		let entryYear = Calendar.current.component(.year, from: entry.createdAt)
		var style = Date.FormatStyle()
			.month(.abbreviated)
			.day()
			.hour(.defaultDigits(amPM: .abbreviated))
			.minute(.twoDigits)
		if entryYear != currentYear {
			style = style.year()
		}
		return entry.createdAt.formatted(style)
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 12) {
			HStack {
				Text(timestamp)
				Spacer()
				Text(entry.duration.compactDurationText)
			}
			.font(.system(size: 12, weight: .medium))
			.foregroundStyle(AppStyle.tertiary)

			Text(entry.headline)
				.font(.system(size: 18, weight: .medium))
				.foregroundStyle(.white)
				.multilineTextAlignment(.leading)
				.lineLimit(3)

			if let processingPhase {
				HStack(spacing: 6) {
					if !processingPhase.isActive, processingPhase != .complete {
						Image(systemName: "exclamationmark.circle")
					} else if processingPhase == .complete {
						Image(systemName: "checkmark.circle.fill")
					} else {
						ProgressView().controlSize(.mini)
					}
					Text(processingPhase.title)
				}
				.font(.system(size: 12, weight: .semibold))
				.foregroundStyle(AppStyle.accent)
				.tint(AppStyle.accent)
			}
		}
		.padding(.vertical, 16)
	}
}
