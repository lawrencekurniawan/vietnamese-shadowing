# Phase 1 implementation: worker, library, and `.vshadow`

This document describes the first-release implementation built on the Phase 0
contracts in `phase0_data_contracts.md`.

## Background synthesis worker

`lib/native/vieneu_synthesis_worker.dart` owns one long-lived isolate and one
`VieNeuFfi` engine. The native engine pointer never leaves that isolate.

The main isolate:

1. Resolves the cache directory and stages runtime assets.
2. Spawns the worker with `Isolate.spawn`.
3. Sends only plain values (`String`, `int`, `bool`, maps, and lists).
4. Receives plain JSON strings for voice lists and synthesis results.

The worker handles these serialized commands:

- `initialize`
- `synthesize`
- `preview`
- `clearCache`
- `clearCachedText`
- `dispose`

Requests are processed one at a time, so synthesis and cache mutation cannot
overlap. If the worker exits unexpectedly, every pending request fails with a
`StateError`. Disposal asks the worker to destroy its engine, waits briefly, and
then kills the isolate if it is still busy.

Stop remains a playback control only. Native inference has no cancellation
token, so the worker keeps running until native synthesis returns. The UI stays
responsive because that work is off the main isolate.

ORT is process-global. The worker is the only production engine creator; the
main isolate no longer constructs a `VieNeuFfi` engine.

## Curated Generate-tab voices

The native catalog still contains the full stable voice set for older library
items and `.vshadow` packages. New synthesis is intentionally limited to the
two southern male presets requested for this release:

- `Adam` (default)
- `Thái Sơn`

`lib/voices/voice_preferences.dart` filters the native catalog through
`selectPreferredVoices()` and resolves `defaultPreferredVoice()`. If either
preferred preset is absent, startup fails with a `StateError` instead of
silently selecting an unrelated voice. The Generate tab therefore shows:

```text
Nam · male · Adam
Nam · male · Thái Sơn
```

A previously saved voice outside this curated set is ignored on startup and
falls back to `Adam`; `resolvePreferredVoice()` isolates and tests that
migration path. Library playback and package import continue to use the voice
metadata stored with each item.

A **Preview** button next to the voice selector synthesizes the fixed sample
`Xin chào, đây là giọng đọc mẫu.` with the selected voice and plays it once at
normal speed. It does not replace the generated full-text audio or save a
library item.

## Durable library

`lib/library/library_repository.dart` stores items under:

```text
Application Support/vieneu/library/<local-uuid>/
  metadata.json
  audio.wav
```

- Audio is copied into the item directory and never points at `vieneu/tts-cache`.
- Saves and imports are staged in a temporary directory and installed with a
  directory rename.
- An explicit item ID is never overwritten. Normal saves get a fresh UUID v4.
- Corrupt items are skipped while listing so one bad directory does not make the
  rest of the library unusable.
- Rename rewrites metadata atomically and leaves audio untouched.
- Delete removes the item directory and its durable audio.

`lib/playback/playback_controller.dart` owns the single active
`PlaybackSession`. The Generate and Library tabs use one controller and are held
in an `IndexedStack`, so changing tabs does not recreate playback state or start
a competing player.

The Library tab supports:

- Save generated audio
- Play and Stop
- Rename
- Delete
- Export WAV
- Export `.vshadow`
- Import `.vshadow`
- Back up the full library and settings to `.vshadowbackup`
- Restore a `.vshadowbackup` file

Deleting the currently playing item stops playback before removing its audio.

## `.vshadow` packages

`.vshadow` is a ZIP-compatible archive with exactly two root entries:

```text
metadata.json
audio.wav
```

The implementation uses:

- `archive ^4.5.2` for ZIP creation and reading
- `crypto ^3.0.7` for SHA-256

The default limits remain 200 MiB for the package and 1 MiB for metadata.

Validation rejects:

- Truncated or malformed archives
- Anything other than exactly two regular root files
- Duplicate entry names
- Absolute paths, traversal components, backslashes, drive separators, and
  unexpected names
- Unsupported metadata schema versions
- Malformed JSON or invalid voice metadata
- Unknown stable voice IDs or a preset/stable-ID mismatch
- Invalid or non-PCM WAV data
- Metadata/audio format or duration mismatches
- Audio byte-length mismatches
- SHA-256 checksum failures
- Oversized packages or metadata

Imports are validated completely before installation. Each import receives a
new local UUID and uses the repository's atomic install path, so an existing
item is never overwritten.

File handling:

- iOS uses the share sheet for export and the document picker for import.
- macOS uses the native save dialog for export and the file picker for import.
- Both `ios/Runner/Info.plist` and `macos/Runner/Info.plist` register the
  `com.example.vietnameseshadowing.vshadow` type and the `.vshadow` extension.
- iOS forwards an opened document through `AppDelegate`/`SceneDelegate`; macOS
  forwards it through `AppDelegate.openFile`/`openURL`. The Dart document channel
  drains the pending path, imports the package, and switches to the Library tab.
- The checksum is an integrity check only, not an authenticity guarantee.

## Full-library backup

`lib/library/vshadow_backup.dart` defines a versioned `.vshadowbackup`
container. The archive contains:

```text
backup.json
items/<item-uuid>/metadata.json
items/<item-uuid>/audio.wav
```

`backup.json` stores:

- Backup schema version and creation time
- Default voice stable ID and preset name
- Playback speed, repeat count, pause duration, and pause mode
- The ordered list of item UUIDs

Each item uses the same portable `VshadowMetadata` and WAV payload validation as
a `.vshadow` package, including voice identity and SHA-256 checksum checks. The
backup limit is 512 MiB, the manifest limit is 2 MiB, and one backup may contain
up to 500 items. Individual item metadata and audio limits match `.vshadow`.

Restore behavior:

- The entire archive, manifest, settings, and every item are validated before
  the first install.
- Backup item IDs are preserved.
- An item whose ID already exists is skipped, never overwritten, so retrying an
  interrupted restore is idempotent.
- Restored playback and voice settings are applied and persisted.
- A voice saved by an older release falls back to the curated default when it
  is no longer offered by the Generate tab.

Cloud storage uses the iOS Files document flow rather than an iCloud
entitlement:

- **Back Up** writes a temporary `.vshadowbackup` file and opens the iOS share
  sheet. **Save to Files** lets the user choose iCloud Drive or Google Drive.
- **Restore** opens the Files picker with the exported
  `com.example.vietnameseshadowing.vshadowbackup` type.
- Both plists declare the type and `.vshadowbackup` extension. The backup is not
  registered as an external-open document type, so restore is always an explicit
  in-app action.
- This works with sideloaded builds and free provisioning, where iCloud
  container entitlements may be unavailable.

No background iCloud sync or OAuth-based Google Drive integration is included.

## Validation

Automated:

- Focused Flutter tests cover stable IDs, the curated voice catalog, both
  curated voices in the Generate flow, voice preview, WAV names, playback, the
  worker protocol, durable storage, cache independence, package validation,
  import safety, export/import round trips, backup validation, idempotent
  restore, settings, and filenames.
- `flutter test --timeout 90s` passes all 108 tests.
- `flutter analyze` reports only `avoid_print` findings.
- `flutter build ios --simulator` succeeds.

Simulator:

- The app launches on iPhone 17 Pro (iOS 26.5, simulator).
- The staged assets load and the worker-owned native engine reaches
  `new_with_ort() COMPLETE`.
- Voices, G2P, and all ONNX sessions initialize inside the worker.
- The Generate tab shows the curated `Nam · male · Adam` voice and the voice
  Preview control; Generate/Library navigation is visible.
- Library actions and `.vshadow` file-picking dialogs require interactive UI
  exercise; they are covered by repository and package-service tests rather than
  claimed as manually tapped flows.

## Known limitations

- Native synthesis cannot be cancelled mid-inference.
- Package, backup, and audio decoding are in-memory; a future version may stream
  large files. The current backup cap is 512 MiB.
- Backups are manual and stored wherever the user chooses in Files. There is no
  automatic iCloud or Google Drive sync.
- Backups are ZIP containers without encryption; the checksum verifies
  integrity, not authenticity or confidentiality.
- The native Files/Finder document-open bridge compiles and has Dart channel
  coverage, but it has not been exercised interactively in this validation
  cycle. The in-app Library import path remains the verified fallback.
