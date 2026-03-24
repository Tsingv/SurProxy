#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SUBMODULE_DIR="$ROOT_DIR/Vendor/CLIProxyAPIPlus"
OUTPUT_DIR="$ROOT_DIR/build/runtime"
OUTPUT_BIN="$OUTPUT_DIR/cliproxyapiplus"
GOCACHE_DIR="${GOCACHE_DIR:-/tmp/SurProxy-go-build}"
GOMODCACHE_DIR="${GOMODCACHE_DIR:-/tmp/SurProxy-go-modcache}"

mkdir -p "$OUTPUT_DIR"
mkdir -p "$GOCACHE_DIR"
mkdir -p "$GOMODCACHE_DIR"

if [[ ! -d "$SUBMODULE_DIR" ]]; then
  echo "Missing submodule: $SUBMODULE_DIR" >&2
  exit 1
fi

pushd "$SUBMODULE_DIR" >/dev/null
GOCACHE="$GOCACHE_DIR" GOMODCACHE="$GOMODCACHE_DIR" go build -o "$OUTPUT_BIN" ./cmd/server
popd >/dev/null

chmod +x "$OUTPUT_BIN"
echo "Built runtime: $OUTPUT_BIN"
