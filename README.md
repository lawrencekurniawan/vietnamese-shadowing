# Vietnamese Shadowing

A Flutter app for Vietnamese listening and shadowing practice. Enter Vietnamese
text, generate speech with a curated southern male voice, loop it at an
adjustable speed, and keep generated clips in a local library. Libraries can be
exported and imported as `.vshadow` packages, or saved and restored as a single
`.vshadowbackup` file through the iOS Files picker (iCloud Drive or Google
Drive).

## Voices

The Generate tab is intentionally limited to:

- `Nam · male · Adam` (default)
- `Nam · male · Thái Sơn`

Existing library items and `.vshadow` packages that use other registered voices
remain playable. A **Preview** button next to the voice selector synthesizes a
short sample with the selected voice without replacing the generated full-text
audio.

## Features

- Background-isolate VieNeu synthesis through the native FFI engine
- Runtime staging of the native voice, G2P, and ONNX assets
- Voice preview, normalized speech-text preview, and adjustable speed, repeat,
  and pause settings
- Durable local library with rename, delete, WAV export, and `.vshadow`
  export/import
- Full-library and settings backup/restore through a single
  `.vshadowbackup` file, saved to iCloud Drive or Google Drive via Files
- External `.vshadow` open handling on iOS and macOS
- One playback owner shared by the Generate and Library tabs

## Backup

The Library tab's **Backup** card exports every saved item plus the current
voice, speed, repeat, and pause settings into one `.vshadowbackup` archive.
On iOS, **Back Up** opens the share sheet; choose **Save to Files**, then select
iCloud Drive or Google Drive. **Restore** opens the Files picker and restores
from either location.

This uses the system document picker instead of an app-specific iCloud
container. Sideloaded builds and free Apple developer provisioning often cannot
use iCloud container entitlements, while the Files picker works without them.
Backups are manual; the app does not run a background iCloud sync.

Restore validates the complete archive before installing items. It preserves
backup item IDs and skips IDs that already exist, so retrying an interrupted
restore does not create duplicates. Existing items are never overwritten.
Backups are ZIP containers and are not encrypted; choose a storage location you
trust.

## Requirements

- Flutter with a current Dart SDK
- Xcode for iOS and macOS builds
- The vendored native assets under `assets/vieneu/` and `assets/sea-g2p/`

This project currently supports iOS and macOS. The Android runner is a Flutter
scaffold and is not wired to the native synthesis engine.

## Development

```sh
flutter pub get
flutter test --timeout 90s
flutter analyze
flutter build ios --simulator
```

## Documentation

- `docs/phase0_data_contracts.md`: stable voice IDs, library metadata, WAV
  filenames, and `.vshadow` package contracts
- `docs/phase1_implementation.md`: worker design, curated voices, library,
  package handling, platform bridges, validation, and known limitations

## Current status

- `flutter test --timeout 90s` passes all 108 tests.
- `flutter analyze` reports only `avoid_print` findings.
- The iOS simulator build launches with `Nam · male · Adam` and reaches
  `Native engine ready`.
- Native macOS runtime validation is pending, and the native
  Files/Finder `.vshadow` open path has not been exercised interactively.
