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
`PlaybackSession`. The Generate, Library, and Practice tabs use one controller
and are held in an `IndexedStack`, so changing tabs does not recreate playback
state or start a competing player.

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

## Practice tab and recording

The dedicated Practice tab records short shadowing takes against a saved
library item:

```text
Application Support/vieneu/practice/<take-uuid>/
  metadata.json
  audio.wav
```

- A take snapshots the library item UUID and title, so it remains playable if
  the original item is later renamed or deleted.
- `metadata.json` stores schema version 1, the take and item UUIDs, creation
  time, WAV format/duration, audio byte length, and a SHA-256 checksum.
- Saves are staged in a temporary directory and installed with a directory
  rename. Existing take IDs are never overwritten.
- One corrupt take is skipped while listing without hiding other recordings.
- Takes are listed newest first and can be played back or deleted.

`PracticeRecordingBridge` in `ios/Runner/AppDelegate.swift` uses
`AVAudioRecorder` and requests microphone permission on first use. Recordings
are 44.1 kHz, mono, 16-bit linear PCM WAV. `NSMicrophoneUsageDescription` is
declared in `ios/Runner/Info.plist`. Recording is a foreground action; leaving
the app stops and saves the current take, and there is no background recording
session.

The Practice tab plays the original with the current Generate settings and
plays takes at 1x for a direct comparison. Both use the shared playback owner,
so starting one source stops or blocks the other rather than creating competing
players.

## Conversation shadowing

`lib/conversation/` discovers short conversational Vietnamese passages and
turns them into ordinary text-to-speech requests:

- `builtin_conversation_pack.dart` provides 24 original everyday exchanges used
  when no network, key, or subtitle is available.
- `subtitle_parser.dart` reads SRT, WebVTT, ASS/SSA, UTF-8/UTF-16 text, and
  ZIP-wrapped downloads. It strips markup and speaker labels, rejects URLs,
  unaccented lines, all-caps cues, and non-dialogue tags, then groups adjacent
  cues into short passages.
- `open_subtitles_source.dart` calls the OpenSubtitles REST API with
  `languages=vi`, `type=movie`, download-count ordering, and AI/machine-translated
  exclusions. It downloads one subtitle per fetch, filters foreign-parts-only
  entries, and ranks candidates by downloads, rating, trusted uploader, and HD
  metadata.
- `subdl_source.dart` provides an alternate provider. It searches SubDL by film
  name with `languages=vi`, `type=movie`, and `hi=0`, filters AI/hearing-impaired
  entries, and ranks by available download/rating metadata. A blank film name
  selects from `subdl_movie_titles.dart`.
- `conversation_service.dart` owns provider selection, seven-day caches, stale
  cache fallback, local imports, and the offline fallback.

The UI exposes separate API-key fields for the two providers and an optional
SubDL film name. Keys and the last film name are saved only in local preferences.
Local subtitle import uses the system file picker and has a 20 MB cap; the file
is parsed on device and is not uploaded. The provider caches live in
`Application Support/vieneu/conversations/`.

**Save & Practice** synthesizes the selected passage with the current curated
voice, saves it through the normal library repository, selects the new item in
the Practice tab, and schedules the usual automatic backup. Subtitle content
remains the property of its creators and is intended for personal study only.

## Practice feedback

The Practice tab can assess a saved take against the generated reference:

- `ios/Runner/AppDelegate.swift` registers the
  `vietnamese_shadowing/practice_assessment` channel.
- `transcribe` uses Apple Speech with the `vi-VN` locale and returns text plus
  timed segments. It requires `supportsOnDeviceRecognition` and sets
  `requiresOnDeviceRecognition = true`; if on-device Vietnamese recognition is
  unavailable, it returns `on_device_recognition_unavailable` instead of
  uploading the take to a server.
- `pitch` parses the PCM WAV in native code, downsamples it, and runs a
  windowed autocorrelation analysis to return voiced F0 frames. Frames that
  cannot be estimated are omitted.
- `practice_analyzer.dart` aligns reference and user words with a
  diacritic-insensitive Levenshtein alignment, compares cadence from timed
  segments and WAV durations, and classifies approximate pitch contours for the
  six Vietnamese tones.
- `practice_assessment_service.dart` caches transcription and pitch by audio
  path and degrades to empty timing/pitch when the bridge cannot provide it.
- `wav_segment_extractor.dart` slices a normal PCM WAV into a standalone WAV so
  a tone-guide word can be replayed from the generated reference.
- `practice_feedback_card.dart` shows recognized-word counts, unclear/extra
  words, cadence notes, tone guidance, and per-word replay controls.

Feedback is approximate and is not phoneme-level pronunciation scoring. It is
kept in memory for the current app session; takes remain the durable artifact and
are included in backups. `NSMicrophoneUsageDescription` and
`NSSpeechRecognitionUsageDescription` are declared in `ios/Runner/Info.plist`.

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
container. Schema version 2 contains:

```text
backup.json
items/<item-uuid>/metadata.json
items/<item-uuid>/audio.wav
practice/<take-uuid>/metadata.json
practice/<take-uuid>/audio.wav
```

`backup.json` stores:

- Backup schema version and creation time
- Default voice stable ID and preset name
- Playback speed, repeat count, pause duration, and pause mode
- The ordered list of item UUIDs
- The ordered list of practice take UUIDs

Each item uses the same portable `VshadowMetadata` and WAV payload validation as
a `.vshadow` package, including voice identity and SHA-256 checksum checks. Each
practice take uses `PracticeTakeMetadata` validation, including WAV format,
duration, byte length, and SHA-256 checksum checks. The backup limit is 512 MiB
of audio, the manifest limit is 2 MiB, and one backup may contain up to 500
items and 500 practice takes. Individual item metadata and audio limits match
`.vshadow`.

Restore behavior:

- The entire archive, manifest, settings, items, and takes are validated before
  the first install.
- Backup item and take IDs are preserved.
- An item or take whose ID already exists is skipped, never overwritten, so
  retrying an interrupted restore is idempotent.
- Restored playback and voice settings are applied and persisted.
- A voice saved by an older release falls back to the curated default when it
  is no longer offered by the Generate tab.
- Schema version 1 backups are accepted as item/settings-only backups. A
  version 1 manifest that declares practice takes is rejected.

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

### Automatic backup

`lib/backup/backup_folder_service.dart` and `BackupFolderBridge` in
`ios/Runner/AppDelegate.swift` implement a folder chooser and persist the chosen
folder as a security-scoped bookmark. `lib/backup/auto_backup_service.dart`
exports the same schema 2 payload and writes one rolling file:

```text
<chosen folder>/vshadow-autobackup.vshadowbackup
```

The rolling file is refreshed about three seconds after library, settings, or
practice-take changes and once on launch when automatic backup is enabled. If a
change happens while an export is running, one follow-up export is scheduled.
Native writes use `NSFileCoordinator` so file-provider folders can replace the
existing file safely. Manual backups keep their timestamped names and are never
overwritten by the automatic file.

There is no background iCloud sync or OAuth-based Google Drive integration.
Automatic backup runs while the app is active and requires the selected folder
to remain available.

## Validation

Automated:

- Focused Flutter tests cover stable IDs, the curated voice catalog, both
  curated voices in the Generate flow, voice preview, WAV names, playback, the
  worker protocol, durable storage, cache independence, package validation,
  import safety, export/import round trips, backup validation, idempotent
  restore, settings, filenames, practice storage, recording channel behavior,
  practice-take backup/restore, version 1 compatibility, automatic backup
  export/write, the automatic-backup folder toggle, subtitle parsing,
  OpenSubtitles/SubDL request shapes and caching, local subtitle import, word
  alignment, cadence, tone feedback, WAV segment extraction, and assessment
  orchestration/caching.
- `flutter test --timeout 90s` passes all 157 automated tests.
- `flutter analyze` reports only `avoid_print` findings.
- `flutter build ios --simulator` succeeds.

Simulator:

- The app launches on iPhone 17 Pro (iOS 26.5, simulator).
- The staged assets load and the worker-owned native engine reaches
  `new_with_ort() COMPLETE`.
- Voices, G2P, and all ONNX sessions initialize inside the worker.
- The Generate tab shows the curated `Nam · male · Adam` voice and the voice
  Preview control; Generate/Library/Practice navigation is visible.
- The Practice tab shows the conversation card and offline pack; the app
  launches with the built debug app on the iOS simulator and the native engine
  reaches `Native engine ready`.
- Library actions, `.vshadow` file-picking dialogs, subtitle file picking,
  automatic-backup folder selection, API-key entry, microphone recording, and
  Apple speech recognition require interactive exercise; they are covered by
  repository, service, channel, parser, analyzer, and widget tests rather than
  claimed as manually tapped device flows.

## Known limitations

- Native synthesis cannot be cancelled mid-inference.
- Package, backup, and audio decoding are in-memory; a future version may stream
  large files. The current backup cap is 512 MiB.
- Automatic backup is not background sync. It refreshes while the app is active,
  and a revoked or moved folder may require choosing the folder again.
- Practice takes are full PCM WAV recordings. They are simple and backup-safe
  but larger than compressed recordings; there is no waveform editor, trim, or
  partial retake yet.
- Recording is foreground-only; leaving the app stops and saves the current
  take instead of continuing in the background.
- Conversation feedback is approximate. Speech recognition is on-device only;
  if the device does not offer on-device Vietnamese recognition, feedback is
  unavailable. Pitch/tone classification is heuristic rather than
  phoneme-level scoring.
- Device-level validation of Vietnamese `SFSpeechRecognizer` output and pitch
  analysis is still required. Simulator builds exercise the UI and channel
  registration but not a real microphone or recognizer session.
- OpenSubtitles and SubDL require personal API keys and consume provider quota.
  Automated tests use injected HTTP responses; no live-account request is run.
- Local subtitle import is capped at 20 MB, and imported lines are not persisted
  across app restarts. Save the generated reference to the Library for durable
  practice material.
- SubDL searches by film name, so a blank field picks from a small curated
  starter list rather than a global popularity feed.
- Subtitle files remain copyrighted. Online discovery is intended for personal
  language study and must follow each provider's terms and quotas.
- Backups are ZIP containers without encryption; the checksum verifies
  integrity, not authenticity or confidentiality.
- The native Files/Finder document-open bridge compiles and has Dart channel
  coverage, but it has not been exercised interactively in this validation
  cycle. The in-app Library import path remains the verified fallback.
- macOS runtime validation is deferred because the bundled
  `libvieneu_core.dylib` does not match the current native engine source. iOS is
  the supported runtime for this release.
