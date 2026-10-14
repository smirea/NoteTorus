import ActivityKit
import SwiftUI
import WidgetKit

@main
struct TalkwardWidgets: WidgetBundle {
	var body: some Widget {
		StartRecordingWidget()
		RecordingLiveActivity()
	}
}

struct StartRecordingWidget: Widget {
	let kind = "StartRecordingWidget"

	var body: some WidgetConfiguration {
		StaticConfiguration(kind: kind, provider: RecordingWidgetProvider()) { _ in
			Link(destination: URL(string: "talkward://record")!) {
				Image(systemName: "mic.fill")
					.font(.title3)
					.widgetAccentable()
			}
			.containerBackground(.black, for: .widget)
		}
		.configurationDisplayName("New recording")
		.description("Start a voice memo.")
		.supportedFamilies([.accessoryCircular])
	}
}

struct RecordingWidgetEntry: TimelineEntry {
	let date: Date
}

struct RecordingWidgetProvider: TimelineProvider {
	func placeholder(in context: Context) -> RecordingWidgetEntry {
		RecordingWidgetEntry(date: .now)
	}

	func getSnapshot(in context: Context, completion: @escaping (RecordingWidgetEntry) -> Void) {
		completion(RecordingWidgetEntry(date: .now))
	}

	func getTimeline(in context: Context, completion: @escaping (Timeline<RecordingWidgetEntry>) -> Void) {
		completion(Timeline(entries: [RecordingWidgetEntry(date: .now)], policy: .never))
	}
}

struct RecordingLiveActivity: Widget {
	var body: some WidgetConfiguration {
		ActivityConfiguration(for: RecordingActivityAttributes.self) { context in
			let presentation = context.state.presentation(isStale: context.isStale)
			Link(destination: context.attributes.recordingURL) {
				HStack(spacing: 13) {
					TalkwardAppIcon(size: 38)

					VStack(alignment: .leading, spacing: 3) {
						Text(context.state.locationName)
							.font(.headline)
							.lineLimit(1)
						Text(context.attributes.startedAt, format: .dateTime.weekday(.abbreviated).month(.abbreviated).day())
							.font(.caption)
							.foregroundStyle(.secondary)
						Text(presentation.statusText)
							.font(.caption)
							.foregroundStyle(.secondary)
							.lineLimit(2)
					}

					Spacer(minLength: 0)

					RecordingElapsedTime(presentation: presentation)
						.font(.title3.weight(.semibold))
						.lineLimit(1)
						.minimumScaleFactor(0.7)
				}
				.padding(.horizontal, 16)
				.padding(.vertical, 14)
			}
			.activityBackgroundTint(.black)
			.activitySystemActionForegroundColor(.white)
		} dynamicIsland: { context in
			let presentation = context.state.presentation(isStale: context.isStale)
			return DynamicIsland {
				DynamicIslandExpandedRegion(.leading) {
					TalkwardAppIcon(size: 32)
				}
				DynamicIslandExpandedRegion(.center) {
					VStack(alignment: .leading, spacing: 2) {
						Text(context.state.locationName)
							.font(.headline)
							.lineLimit(1)
						Text(presentation.statusText)
							.font(.caption)
							.foregroundStyle(.secondary)
							.lineLimit(2)
					}
				}
				DynamicIslandExpandedRegion(.trailing) {
					RecordingElapsedTime(presentation: presentation)
				}
			} compactLeading: {
				RecordingStatusIcon(presentation: presentation)
			} compactTrailing: {
				RecordingElapsedTime(presentation: presentation)
					.frame(width: 52)
			} minimal: {
				RecordingStatusIcon(presentation: presentation)
			}
			.widgetURL(context.attributes.recordingURL)
		}
	}
}

private struct RecordingElapsedTime: View {
	let presentation: RecordingActivityAttributes.Presentation

	var body: some View {
		Group {
			if let interval = presentation.timerInterval {
				HStack(spacing: 0) {
					Text("~")
					Text(timerInterval: interval, countsDown: false, showsHours: false)
				}
			} else {
				Text(presentation.elapsedText)
			}
		}
		.monospacedDigit()
	}
}

private struct RecordingStatusIcon: View {
	let presentation: RecordingActivityAttributes.Presentation

	var body: some View {
		if presentation.timerInterval != nil {
			TalkwardAppIcon(size: 22)
		} else {
			Image(systemName: presentation.symbolName)
				.foregroundStyle(.white)
		}
	}
}

private struct TalkwardAppIcon: View {
	let size: CGFloat

	var body: some View {
		Image("TalkwardMark")
			.resizable()
			.frame(width: size, height: size)
			.clipShape(.rect(cornerRadius: size * 0.22))
	}
}
