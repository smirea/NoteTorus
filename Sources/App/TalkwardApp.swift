import SwiftUI

@main
struct TalkwardApp: App {
	@State private var store: JournalStore
	@State private var recordingSession: RecordingSession

	init() {
		_ = ProcessingTemporaryFiles.launchDate
		#if DEBUG
		ProcessingReliabilityContractChecks.prepareNativeBackgroundSmoke()
		#endif
		let store = JournalStore()
		_store = State(initialValue: store)
		_recordingSession = State(initialValue: RecordingSession(store: store))
	}

	var body: some Scene {
		WindowGroup {
			RootView(store: store, recordingSession: recordingSession)
				.preferredColorScheme(.dark)
				.tint(AppStyle.accent)
				.task {
					_ = await ProcessingTemporaryFiles.shared.cleanOnce()
					#if DEBUG
					await LocalModelProbe.runFromLaunchArguments()
					await MemoSeed.run(store: store)
					#endif
					#if DEBUG
					await LocationContractChecks.runFromLaunchArguments()
					await RecordingContractChecks.runFromLaunchArguments()
					await RecordingActivityContractChecks.runFromLaunchArguments(session: recordingSession)
					await RecordingPresentationContractChecks.runFromLaunchArguments()
					await CalendarOccurrenceContractChecks.runFromLaunchArguments()
					await CalendarNavigationContractChecks.runFromLaunchArguments()
					await PlaybackContractChecks.runFromLaunchArguments()
					await WaveformDecoderContractChecks.runFromLaunchArguments()
					await PlaybackWaveformContractChecks.runFromLaunchArguments()
					await StorageContractChecks.runFromLaunchArguments()
					await AudioFinalizationContractChecks.runFromLaunchArguments()
					await TranscriptionContractChecks.runFromLaunchArguments()
					await ModelOutcomeContractChecks.runFromLaunchArguments()
					await MemoTaskContractChecks.runFromLaunchArguments()
					await WeeklyRecordingMetricContractChecks.runFromLaunchArguments()
					await ModelContextContractChecks.runFromLaunchArguments()
					await ReflectionContextContractChecks.runFromLaunchArguments()
					await ProcessingRepositoryContractChecks.runFromLaunchArguments()
					await ProcessingWorkerContractChecks.runFromLaunchArguments()
					await ServiceAdmissionContractChecks.runFromLaunchArguments()
					await ProcessingReliabilityContractChecks.runFromLaunchArguments()
					await ProcessingReliabilityContractChecks.runNativeBackgroundSmoke()
					await ICloudMirrorContractChecks.runFromLaunchArguments()
					await ICloudStoreContractChecks.runFromLaunchArguments()
					await CloudStateContractChecks.runFromLaunchArguments()
					await CloudFileAccessContractChecks.runFromLaunchArguments()
					await ICloudProviderContractChecks.runFromLaunchArguments()
					await CloudStoreReliabilityContractChecks.runFromLaunchArguments()
					#endif
				}
		}
	}
}
