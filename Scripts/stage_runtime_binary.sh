#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 /path/to/cliproxyapiplus" >&2
  exit 1
fi

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE_BIN="$1"
TARGET_DIR="$ROOT_DIR/SurProxy/Resources/Runtime"
TARGET_BIN="$TARGET_DIR/cliproxyapiplus"

if [[ ! -f "$SOURCE_BIN" ]]; then
  echo "Binary not found: $SOURCE_BIN" >&2
  exit 1
fi

mkdir -p "$TARGET_DIR"
cp "$SOURCE_BIN" "$TARGET_BIN"
chmod +x "$TARGET_BIN"

echo "Staged runtime binary at: $TARGET_BIN"
