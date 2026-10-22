# Vietnamese Shadowing

A Flutter app for Vietnamese listening and shadowing practice. Enter Vietnamese
text, generate speech with a curated southern male voice, loop it at an
adjustable speed, and keep generated clips in a local library. Libraries can be
exported and imported as `.vshadow` packages.

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
- External `.vshadow` open handling on iOS and macOS
- One playback owner shared by the Generate and Library tabs

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

- `flutter test --timeout 90s` passes all 99 tests.
- `flutter analyze` reports only `avoid_print` findings.
- The iOS simulator build launches with `Nam · male · Adam` and reaches
  `Native engine ready`.
- Native macOS runtime validation is pending, and the native
  Files/Finder `.vshadow` open path has not been exercised interactively.
