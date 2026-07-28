#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="${TMPDIR:-/tmp}/crypta-data-safety-tests"
BIN="$BUILD_DIR/DataSafetyTests"

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

xcrun swiftc \
  "$ROOT_DIR/Crypta/ApprovedCopy.swift" \
  "$ROOT_DIR/Crypta/Models.swift" \
  "$ROOT_DIR/Crypta/ExternalToolRunner.swift" \
  "$ROOT_DIR/Crypta/EncryptedMediaFormat.swift" \
  "$ROOT_DIR/Crypta/CryptaStorageSupport.swift" \
  "$ROOT_DIR/Crypta/CryptaStore.swift" \
  "$ROOT_DIR/Crypta/CryptaStore+Index.swift" \
  "$ROOT_DIR/Crypta/InMemoryMediaPlaybackSource.swift" \
  "$ROOT_DIR/Crypta/DecryptedMediaSessionManager.swift" \
  "$ROOT_DIR/Crypta/VideoThumbnailLoader.swift" \
  "$ROOT_DIR/scripts/DataSafetyTests.swift" \
  -o "$BIN"

"$BIN"
