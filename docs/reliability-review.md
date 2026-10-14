# Reliability and architecture review

The app should treat captured audio as the primary product. Transcription, summaries, cloud exports, waveforms, and system presentations are optional projections of saved recordings. Most failures in the original implementation came from letting these layers share lifetimes or infer success from incomplete state.

## Fundamental decisions

| Original weakness | Resulting failure | Implemented boundary |
|---|---|---|
| Recording belonged to a screen; hardware callbacks implied user intent | Navigation could discard capture; a late permission or route callback could restart it | App-owned recording session, explicit intent/state, generation checks, and audio-session ownership |
| One library JSON document and optimistic save/delete | One damaged entry could hide the library; failed writes could claim success or resurrect deleted audio | Independent atomic manifests, stable recording IDs, preserved migration originals, and durable deletion tombstones |
| A recording container needed a clean finish to be playable | Abrupt exit left audio that metadata alone could not recover | Streaming AAC ADTS, native M4A remux, complete validation, publish-then-manifest commit, source cleanup last |
| Generated titles and in-memory tasks represented processing progress | Interrupted work stayed incomplete or repeated completed work; canceled native requests overlapped replacements | Durable stage/request/attempt/source records; atomic output plus advancement; one worker and permits held until actual native cleanup |
| Async output was trusted after its input changed | Old analysis or activities could replace current state | Narrow edits, saved source revisions, immediate intent invalidation, and exact durable receipts |
| Every update repeated derived work | Repeated directory scans, file rewrites, waveform decoding, and model calls competed with capture | Incremental export index and receipts, bounded waveform caches, coalesced workers, capture priority |
| Remote configuration failure resembled absence | Unavailable cloud state could be overwritten with defaults | Explicit absent/unavailable/damaged/conflicting states, provisional local edits, conditional remote creation |
| Model prompts assumed inputs fit | Long memos could be omitted or exceed context | Full request budgets, ordered complete passages, bounded reduction |
| Event IDs and short title prefixes were treated as proof | Wrong recurring instance, cross-calendar match, or unrelated event | Exact occurrence selection and ambiguity rejection |
| Recording activities ran independently of capture | A killed process could leave an indefinitely advancing recording timer | Capture-specific ownership, confirmed progress, bounded estimated timers, orphan cleanup on relaunch |
| The weekly graph used invented values | A visual suggested a meaningful trend without a measurement | Daily minutes from available saved recordings, grouped by recording date across seven local calendar days |

These changes preserve a small native app: no new service or third-party dependency is required. The repository owns durable truth, the store coordinates optional work, and each screen owns its temporary interaction. A canceled caller can stop waiting without pretending an uncooperative native service has finished.

The key owners are [`RecordingSession`](../Sources/App/RecordingSession.swift) and [`AudioRecorder`](../Sources/App/AudioRecorder.swift) for capture; [`JournalRepository`](../Sources/App/JournalRepository.swift) for durable records; [`ServiceAdmission`](../Sources/App/ServiceAdmission.swift) and [`JournalStore`](../Sources/App/JournalStore.swift) for optional work; [`ICloudDriveMirror`](../Sources/App/ICloudDriveMirror.swift) for exports; and [`CalendarOccurrenceIdentity`](../Sources/App/CalendarOccurrenceIdentity.swift) for attached events. [`FEATURES.md`](../FEATURES.md) is the behavioral regression contract.

## Performance evidence

An unchanged 400-note export fixture went from 800 directory scans and 400 JSON writes in about 2.583 seconds to one scan and zero writes in about 0.0986 seconds. A repeated five-minute waveform load went from a full decode in about 0.086 seconds to a cache lookup in about 0.000126 seconds, with identical 52-bin output. The first waveform decode still costs about 0.102 seconds. These are local fixture measurements, not physical-device latency or iCloud upload measurements.

Weekly Review waits for library loading before computing totals. An unreadable library reports unavailable totals; it cannot silently become an empty zero week. Completed local metrics remain visible when optional reflection fails.

## Deliberate tradeoffs

- Local storage is authoritative. iCloud files are browsable exports and configuration restoration; they are not a multi-device note merge protocol. A local provider write does not prove another device received it.
- Audio recovery retains complete written packets, but codec/filesystem buffering can lose the final tail. Keeping the source through validated publication costs temporary disk space and avoids claiming an unreadable recording is saved.
- iOS can delay stale Live Activity redraw. A bounded timer and explicit last-confirmed wording prevent an unlimited recording claim; reopening clears activities from the previous process.
- Native work that never exits retains its quarantined service permit. Relaunch may be needed to recover that optional service. Microphone admission does not wait for it.
- Exact native calendar detail lookup uses the saved calendar and small date windows, but EventKit remains synchronous. Moving it to a dedicated owner is justified if physical-device traces show an interaction delay; broader queries or heuristic matches would weaken correctness.

## Validation

Validated on 2026-09-17 in an isolated iPhone 17 Pro Simulator running iOS 26.5. The reminder feature, its suites, and its benchmark were removed later; this record is kept as measured:

- All 40 registered contract suites passed in 19.2 seconds. All 12 deterministic benchmark checks passed separately in 1.2 seconds; zero semantic cases were assessed. Run them with the [canonical Simulator command](testing.md).
- Debug and unsigned Release Simulator builds passed. The design rules and final feature-contract review passed.
- Actual native AAC writer termination recovered 3.181 seconds under the same recording ID. Termination between M4A publication and manifest commit recovered 3.065 seconds under the same ID. Earlier 60-second native media measurements also validated full-stream remux; these synthetic writers need no microphone.
- Native recording and reminder ActivityKit request/update/replacement/end checks passed. Killing the app with two seeded recording activities and relaunching found the exact same activity IDs and ended both.
- Simulator screenshots covered stopped capture, failed save/discard, incomplete processing, playback waveform, feedback retry/cancellation states, exact recurring-event selection, reminder/recording Lock Screen presentations, truthful weekly metrics, and Settings at normal and larger text sizes. Settings headings now scroll with their controls without covering content.
- Actual navigation and recurring-occurrence selection were exercised while computer control was available. The host later locked; remaining visual states used Simulator launch fixtures and screenshots. The additional attachment-off tap and final feedback Cancel tap were not manually repeated; their state transitions have contract coverage.

Native Apple Speech reported no compatible audio format for the selected language in this Simulator. Native Foundation Models token counting and a simple response returned GenerationError -1 despite reported model availability. They remain unverified here. The host native tokenizer separately validated the runtime 8,192-token context with a largest reserved request of 8,186 tokens; this does not establish generated-answer quality.

The meaningful checks exercise production state machines with controlled service seams, real temporary-file failures, held cancellation, restarts, revision races, and native media operations. They prove those boundaries; they do not establish language-model accuracy or physical microphone behavior.

The Simulator has no working microphone input on this host. Actual microphone capture, locked/background recording, Bluetooth transitions, calls, media-service resets, low-storage behavior under a live capture, and device power loss still require an iPhone. Native Speech and Foundation Models generation are reported separately from deterministic substitutes. Real iCloud upload/conflict behavior and real calendar-account data were not mutated during this review.

## Recommended next acceptance gate

To validate the recorder's central promise, run a sustained physical-iPhone capture and recovery session before relying on it for irreplaceable audio. Exercise lock/background, deliberate pause, incoming interruptions, route changes, storage pressure, and forced termination; compare recovered duration and audible content. Then evaluate native transcription and model output on representative long recordings. Keep these device results separate from the repeatable Simulator regression command.
