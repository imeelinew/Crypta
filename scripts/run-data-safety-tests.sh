#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="${TMPDIR:-/tmp}/crypta-data-safety-tests"
BIN="$BUILD_DIR/DataSafetyTests"

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

xcrun swiftc \
  "$ROOT_DIR/Crypta/Models.swift" \
  "$ROOT_DIR/Crypta/SubtitleSRT.swift" \
  "$ROOT_DIR/Crypta/SubtitleConfiguration.swift" \
  "$ROOT_DIR/Crypta/SubtitleProcessRunner.swift" \
  "$ROOT_DIR/Crypta/SubtitleNormalizer.swift" \
  "$ROOT_DIR/Crypta/SubtitleLLMService.swift" \
  "$ROOT_DIR/Crypta/SubtitleEmbedder.swift" \
  "$ROOT_DIR/Crypta/SubtitleGenerator.swift" \
  "$ROOT_DIR/Crypta/CryptaStore.swift" \
  "$ROOT_DIR/Crypta/InMemoryMediaPlaybackSource.swift" \
  "$ROOT_DIR/Crypta/DecryptedMediaSessionManager.swift" \
  "$ROOT_DIR/Crypta/VideoThumbnailLoader.swift" \
  "$ROOT_DIR/scripts/DataSafetyTests.swift" \
  -o "$BIN"

"$BIN"
