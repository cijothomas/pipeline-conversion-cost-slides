#!/usr/bin/env bash
# One-time setup: download otelcol-contrib release binary and build telemetrygen.
# Idempotent — re-running is safe.

set -euo pipefail

cd "$(dirname "$0")/.."

OTELCOL_VERSION="${OTELCOL_VERSION:-0.116.0}"   # pin so results are reproducible
BIN_DIR="bin"
mkdir -p "$BIN_DIR"

# --- detect host ---
case "$(uname -s)-$(uname -m)" in
  Darwin-arm64)  PLATFORM="darwin_arm64" ;;
  Darwin-x86_64) PLATFORM="darwin_amd64" ;;
  Linux-x86_64)  PLATFORM="linux_amd64"  ;;
  Linux-aarch64) PLATFORM="linux_arm64"  ;;
  *) echo "Unsupported host: $(uname -s)-$(uname -m)"; exit 1 ;;
esac

# --- otelcol-contrib ---
if [[ ! -x "$BIN_DIR/otelcol-contrib" ]]; then
  TARBALL="otelcol-contrib_${OTELCOL_VERSION}_${PLATFORM}.tar.gz"
  URL="https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download/v${OTELCOL_VERSION}/${TARBALL}"
  echo "Downloading $URL"
  curl -fsSL -o "$BIN_DIR/$TARBALL" "$URL"
  tar -xzf "$BIN_DIR/$TARBALL" -C "$BIN_DIR" otelcol-contrib
  rm "$BIN_DIR/$TARBALL"
  chmod +x "$BIN_DIR/otelcol-contrib"
fi
echo "otelcol-contrib: $("$BIN_DIR/otelcol-contrib" --version)"

# --- telemetrygen ---
if [[ ! -x "$BIN_DIR/telemetrygen" ]]; then
  if ! command -v go >/dev/null 2>&1; then
    echo "go is required to install telemetrygen (brew install go)"
    exit 1
  fi
  echo "Building telemetrygen…"
  GOBIN="$(pwd)/$BIN_DIR" go install \
    "github.com/open-telemetry/opentelemetry-collector-contrib/cmd/telemetrygen@v${OTELCOL_VERSION}"
fi
echo "telemetrygen: installed at $BIN_DIR/telemetrygen"

# --- pprof helpers (just need go tool pprof, already part of go) ---
if ! command -v go >/dev/null 2>&1; then
  echo "WARNING: go not found — you'll need it to render flamegraphs from cpu.prof"
fi

echo
echo "Setup complete. Try:"
echo "  ./scripts/run.sh passthrough 10000"
