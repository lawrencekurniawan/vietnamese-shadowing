# Vietnamese Shadowing

A Flutter app for Vietnamese listening and shadowing practice. Enter Vietnamese
text, generate speech with a curated southern male voice, loop it at an
adjustable speed, and keep generated clips in a local library. A dedicated
Practice tab lets you record takes against any saved clip and compare them with
the original. Individual clips can be exported as `.vshadow` packages.
Libraries, settings, and practice takes can be saved and restored as a single
`.vshadowbackup` file through the iOS Files picker (iCloud Drive or Google
Drive). Automatic backups can keep one rolling backup in a folder you choose.

## Voices

The Generate tab is intentionally limited to:

- `Nam · male · Adam` (default)
- `Nam · male · Thái Sơn`

Existing library items and `.vshadow` packages that use other registered voices
remain playable. A **Preview** button next to the voice selector synthesizes a
short sample with the selected voice without replacing the generated full-text
audio.

## Practice

The Practice tab works with clips already saved in the Library. Choose an item,
play the original, record yourself, then play the take back for comparison.
Takes are saved automatically when recording stops and can be deleted later.
Leaving the app while recording also stops and saves the current take. Recording
uses the iOS microphone permission and writes a 44.1 kHz mono PCM WAV so takes
can travel inside backups.

## Features

- Background-isolate VieNeu synthesis through the native FFI engine
- Runtime staging of the native voice, G2P, and ONNX assets
- Voice preview, normalized speech-text preview, and adjustable speed, repeat,
  and pause settings
- Durable local library with rename, delete, WAV export, and `.vshadow`
  export/import
- Full-library, settings, and practice-take backup/restore through a single
  `.vshadowbackup` file, saved to iCloud Drive or Google Drive via Files
- Automatic backup to a folder chosen once in Files, with one rolling
  `vshadow-autobackup.vshadowbackup` file updated after changes and on launch
- Dedicated Practice tab with native microphone recording, saved takes, and
  original/take playback
- External `.vshadow` open handling on iOS and macOS
- One playback owner shared by the Generate, Library, and Practice tabs

## Backup

The Library tab's **Backup** card exports every saved item, the current voice,
speed, repeat, and pause settings, and every saved practice take into one
`.vshadowbackup` archive. On iOS, **Back Up** opens the share sheet; choose
**Save to Files**, then select iCloud Drive or Google Drive. **Restore** opens
the Files picker and restores from either location.

### Automatic backup

Turn on **Automatic backup** and choose a folder once in the Files picker.
After library, setting, or practice-take changes, the app waits about three
seconds and writes one rolling
`vshadow-autobackup.vshadowbackup` into that folder. It also refreshes the
rolling backup when the app launches. Choose iCloud Drive, Google Drive, or
**On My iPhone**; the folder is remembered with a security-scoped bookmark.

This uses the system folder picker instead of an app-specific iCloud container.
Sideloaded builds and free Apple developer provisioning often cannot use iCloud
container entitlements, while the Files picker works without them. Automatic
backup runs while the app is active; it is not a background iCloud sync.
Timestamped manual backups are never overwritten by the rolling automatic file.

Restore validates the complete archive before installing items or takes. It
preserves backup item and take IDs and skips IDs that already exist, so retrying
an interrupted restore does not create duplicates. Existing items and takes are
never overwritten. Backups are ZIP containers and are not encrypted; choose a
storage location you trust. Backups made by the previous schema version remain
restorable.

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

- `flutter test --timeout 90s` passes all 132 tests.
- `flutter analyze` reports only `avoid_print` findings.
- The iOS simulator build launches with `Nam · male · Adam` and reaches
  `Native engine ready`.
- Native folder selection and microphone recording are covered by service,
  channel, and widget tests; they still require interactive device validation.
- Native macOS runtime validation is pending, and the native
  Files/Finder `.vshadow` open path has not been exercised interactively.
