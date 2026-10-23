# Phase 0 data contracts and synthesis boundary

This document records the contracts established in Phase 0. The implemented
worker, library UI, playback ownership, and `.vshadow` file registration are
described in `phase1_implementation.md`.

## Stable voice IDs

The native preset/display name remains the lookup key for synthesis. Stable IDs
are a separate, portable identity stored in settings, library metadata, and
`.vshadow` packages.

IDs are frozen in `lib/voices/voice_identity.dart` and validated against the
actual catalog in `assets/vieneu/voices_v3_turbo.json` by tests. They are
lowercase ASCII, hyphen-separated, unique, independent of list position, and at
most 32 characters. Unknown IDs resolve to `null`; they never fall back to an
unrelated voice.

The existing display order is unchanged: accent **Bắc → Nam → Trung**, then
gender, then display name.

## Local library metadata

Local items live under `Application Support/vieneu/library/<uuid>/`.

```text
vieneu/
  assets/                 # staged runtime assets
  tts-cache/              # temporary, expires after seven days
  library/
    <uuid>/
      metadata.json
      audio.wav
  practice/
    <uuid>/
      metadata.json
      audio.wav
  conversations/
    open_subtitles_cache.json
    subdl_cache.json
```

`library/<uuid>/audio.wav` is the durable audio reference. A library item must
never point at `tts-cache`; clearing or expiring the cache must not affect a
saved item.

`metadata.json` uses schema version `1`. Required fields:

- `schema_version`: integer, currently `1`
- `item_id`: local UUID v4, assigned locally
- `title`: editable, non-empty
- `original_text`: original user input
- `normalized_text`: spoken/normalized text
- `voice`: stable voice metadata
- `created_at_utc`: ISO-8601 UTC timestamp ending in `Z`
- `audio`: WAV format metadata
- `audio_file`: must be `audio.wav`

`voice` contains:

- `stable_id`: portable stable voice ID
- `preset_name`: native synthesis lookup key
- `display_name`: human-readable name
- `description`, `gender`, `accent`, `style`: display metadata

`audio` contains `format` (`wav`), `sample_rate`, `channels`, `bit_depth`, and
optionally `duration_seconds`.

Serialization validates the version, UUID, non-empty text/title, UTC timestamp,
audio file name, voice fields, and audio format. Unknown local metadata versions
are rejected.

## Practice take metadata

Practice recordings live under `Application Support/vieneu/practice/<uuid>/`.
Each take uses schema version `1` and contains:

- `schema_version`: integer, currently `1`
- `take_id`: local UUID v4, also the directory name
- `library_item_id`: UUID of the source library item
- `item_title`: snapshot of the source title
- `created_at_utc`: ISO-8601 UTC timestamp ending in `Z`
- `audio`: WAV format metadata
- `audio_bytes`: exact byte length of `audio.wav`
- `audio_sha256`: lowercase SHA-256 checksum of `audio.wav`

The fixed audio filename is `audio.wav`; recordings are 44.1 kHz, mono, 16-bit
linear PCM WAV. A take remains valid if its source library item is later renamed
or deleted. Unknown versions, invalid UUIDs/checksums, and audio format or
duration mismatches are rejected.

## Conversation sources and feedback

Conversation practice is a discovery aid on top of the durable library. It does
not add a second copy of library audio or takes.

Provider caches live under `Application Support/vieneu/conversations/`:

- `open_subtitles_cache.json`
- `subdl_cache.json`

Each cache records the fetched UTC time, downloaded source title/metadata, and
the parsed lines. Entries are fresh for seven days. A stale entry is used only
when a live request fails, so an outage can fall back to the last successful
result. The caches contain subtitle text and must be treated as local,
copyrighted study material.

Provider settings are stored in local preferences, not in the library, caches,
`.vshadow` packages, or `.vshadowbackup` files:

- `vshadow_opensubtitles_api_key`
- `vshadow_subdl_api_key`
- `vshadow_subdl_film_name`

Online and local-import lines are transient UI state. A local SRT/VTT/ASS/SSA/ZIP
file is parsed on device, is not uploaded, and is not persisted after the app
restarts. **Save & Practice** produces a normal durable library item through the
existing synthesis and library contract; that item and any subsequent practice
takes are backed up normally.

Assessment feedback is also transient. It is keyed to a take ID and held in
memory for the current session. No feedback text or pitch data is written into
practice metadata or backups.

Word matching folds Vietnamese diacritics for a forgiving comparison. Tone
guidance uses a heuristic pitch-contour classification, not phoneme-level
scoring. The result is approximate and device/bridge dependent.

## `.vshadow` package contract

A `.vshadow` package is a ZIP-compatible archive containing exactly two root
entries:

```text
metadata.json
audio.wav
```

No model weights, ONNX files, native libraries, nested directories, duplicate
entries, absolute paths, or application assets are allowed. The implemented
limits are **200 MiB for the package** and **1 MiB for metadata**.

`metadata.json` uses its own schema version, currently `1`. Required fields:

- `schema_version`: integer, currently `1`
- `title`, `original_text`, `normalized_text`
- `voice`: the same portable voice metadata shape as the local library
- `created_at_utc`: ISO-8601 UTC timestamp ending in `Z`
- `audio`: WAV format metadata
- `audio_bytes`: byte length of `audio.wav`
- `audio_sha256`: lowercase SHA-256 of `audio.wav`

The checksum is an integrity check only. It is not an authenticity or security
guarantee.

Version compatibility rules:

- Version `1` readers accept exactly schema version `1`.
- Unknown JSON fields may be ignored inside a supported version.
- Unsupported versions, missing required fields, malformed values, invalid WAV
  data, unexpected archive entries, duplicate names, path traversal, and
  oversized inputs must be rejected before installation.
- Imports assign a new local UUID and must not overwrite an existing item.
- Imports should be staged and installed atomically.

ZIP creation/extraction, strict validation, atomic import, file picking, and
document registration are implemented in Phase 1. `archive` and `crypto` are
direct dependencies. See `phase1_implementation.md` for the validation rules,
platform integration, and current limits.

## WAV export filenames

The export convention is:

```text
<text-slug>_<stable-voice-id>_<YYYY-MM-DD>_<HHmmss>.wav
```

Rules:

- The text slug comes from the original input text, not normalized speech text.
- Vietnamese diacritics and `đ`/`Đ` are folded to ASCII.
- The slug contains only lowercase ASCII letters, digits, and single hyphens.
- The text slug is at most 60 characters; the voice component is at most 32.
- Empty text slugs fall back to `audio`.
- The timestamp is local time. Stored metadata timestamps remain UTC.
- Collisions use `-2`, `-3`, and so on.
- The generated name contains no path separators, so it cannot traverse paths.

The utility is `lib/library/wav_export_filename.dart`.

## Background synthesis investigation

> **Phase 1 update:** the worker design below is implemented in
> `lib/native/vieneu_synthesis_worker.dart` and is now the production synthesis
> path. The remaining subsections record the Phase 0 investigation.

### Phase 0 behavior

`_generateTestAudio()` calls `VieNeuFfi.synthesizeToWav()` synchronously on the
Flutter UI isolate. That call enters the native C ABI, which performs G2P,
normalization, cache lookup, ONNX inference, and WAV writing. The UI is blocked
for the duration of that call.

### Native boundary evidence

- `vieneu_tts_create` returns a raw `*mut VieNeuTtsNativeEngine`.
- The engine owns `G2PEngine` plus four ORT `Session`s.
- `vieneu_tts_synthesize_to_wav` casts the pointer to `&mut` and calls a
  blocking `synthesize_text`.
- The C ABI does not expose a thread-safety or `Send`/`Sync` contract.
- Dart FFI pointers are native resources, not values that may be shared between
  isolates.
- `ort` keeps a process-global environment (`ort::init()` / `init_from` must be
  configured before sessions are created). Phase 0 initialized it once per
  process on the UI isolate; Phase 1 initializes it inside the worker.
- Native synthesis has no cancellation token or stop request. A worker isolate
  would remain busy until synthesis returns; it could not process a stop message
  during inference.

### Phase 0 decision (historical)

Phase 0 did not move synthesis to a worker isolate. A safe implementation
required a deliberate execution-boundary change:

1. Stage assets and resolve the cache directory on the main isolate.
2. Spawn one long-lived synthesis isolate that creates and owns its own
   `VieNeuFfi` engine. Never transfer the pointer.
3. Send only plain values (UTF-8 text, stable/preset IDs, root paths) and receive
   plain result objects or serialized errors.
4. Route voice listing, synthesis, whole-cache clearing, per-text cache clearing,
   and disposal through the worker protocol.
5. Complete pending requests with an error if the worker exits unexpectedly.
6. Pair worker shutdown with engine destruction.
7. Keep playback and settings on the main isolate.
8. Do not advertise cancellation until native code supports it. A worker keeps
   the UI responsive but does not make inference interruptible.

This design is now implemented. The main isolate stages assets and owns the UI;
the worker owns its engine and handles voice listing, synthesis, preview, cache
operations, and disposal. Pending requests fail if the worker exits. Stop remains
playback-only because native inference has no cancellation token. See
`phase1_implementation.md` for the implementation and validation details.
