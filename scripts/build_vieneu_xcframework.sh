#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CRATE="$ROOT/native/vieneu_core"
OUTPUT="$ROOT/ios/Runner/Native/VieNeuCore.xcframework"

cd "$ROOT"

cargo build --release \
  --manifest-path "$CRATE/Cargo.toml" \
  --target aarch64-apple-ios

cargo build --release \
  --manifest-path "$CRATE/Cargo.toml" \
  --target aarch64-apple-ios-sim

rm -rf "$OUTPUT"

xcodebuild -create-xcframework \
  -library "$CRATE/target/aarch64-apple-ios/release/libvieneu_core.a" \
  -library "$CRATE/target/aarch64-apple-ios-sim/release/libvieneu_core.a" \
  -output "$OUTPUT"

echo "Created: $OUTPUT"
