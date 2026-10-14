# Cloud storage

Local note manifests and audio remain authoritative. iCloud Drive is a browsable export destination; the app does not import or merge note exports. Recording does not wait for cloud discovery or configuration restoration.

## Committed changes

Each note manifest has a content revision separate from its processing attempt and input revisions. Only changes to exported content or deletion advance the content revision. An export acknowledgment must match the current content revision and saved/deleted state; an old result cannot clear a newer edit or tombstone. Acknowledgments and retry bookkeeping do not generate another export.

Successful audio and metadata receipts retain file signatures without duplicating the transcript. A directory scan validates those receipts, so an unchanged repair pass after restart performs no audio copy or note JSON write. Missing or replaced files are repaired. A changed title rewrites its JSON only.

One Store worker coalesces new requests into the latest committed snapshot. Mirror file access runs on a serial utility queue through `NSFileCoordinator`, uses its accessor URLs, and propagates both coordination and file-operation failures. Cancellation and a 30-second access deadline reach the coordinator; an accessor already running retains ownership until it exits. New capture cancels optional cloud work and postpones its replacement.

Audio is staged beside its destination and published before matching metadata. The old city-named pair is removed only after the new pair succeeds. Deletions match generated UUID filenames, preserve unrelated files, and retain their tombstones and legacy aliases across local audio cleanup and restart. Abandoned staging files use an app-specific timestamped name and are cleaned after a later launch.

Transient failures retry after 5 seconds, 30 seconds, and 3 minutes, then wait for another relevant change or explicit repair. Foreground, account changes, and Settings’ Try Again action trigger repair. A failure to persist cloud progress locally stops automatic retry until a later repair; the original note and deletion intent remain intact.

## Configuration

A readable local `config.json` stays authoritative. Schema versions 1 and 2 are supported; a settings payload is required. Damaged or unsupported originals are preserved. Local read failure never means absence, and changing a setting cannot replace a blocked original.

When local configuration is missing, `config-pending.json` stores the initial baseline, current edits, and explicit API-key-edit intent. Those values survive restart without publishing defaults to iCloud. A remote configuration is restored only after readable current data is available, then narrow local changes are applied to it before the canonical local file is atomically saved. Named places merge by stable ID. Explicit key clearing survives even when the original baseline key was empty.

Cloud absence requires completed metadata discovery and a coordinated missing-file result. Creation then rechecks absence inside coordinated access. If a file appears during that boundary, it is read and restored instead of overwritten. Downloading, stale, unavailable, damaged, unsupported, and conflicting remote configurations remain unresolved and preserve local provisional edits. Note exports continue independently.

Config export acknowledgments use a fingerprint of the exact committed bytes. Status is kept separately in `config-cloud.json`; a crash after a canonical write still leaves its new fingerprint pending. Settings bindings read current values and persist baseline-to-current intent, preventing an older open sheet or queued edit from erasing unrelated restored fields.

## Verification limits

Temporary-directory and Simulator contracts exercise real atomic file writes, manifest failures, restart behavior, native coordination, cancellation, and injected provider states. A completed write means the local iCloud provider accepted the file. It does not prove server upload, cross-device delivery, real account discovery, eviction timing, or conflict propagation; those require device/account testing.
