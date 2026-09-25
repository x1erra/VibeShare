#!/bin/bash
# Produce a reproducible x86_64 Linux Mint headless bundle.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$ROOT/dist/vibeshare-linux-amd64}"
mkdir -p "$OUT"
(
  cd "$ROOT/router"
  GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build -trimpath -o "$OUT/vibeshare-router" .
  GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build -trimpath -o "$OUT/vibeshare" ./cmd/vibeshare
)
VIBESHARE_TARGET_OS=linux "$ROOT/scripts/fetch-cliproxyapi.sh" amd64 "$OUT/cli-proxy-api"
cp "$ROOT/src/Sources/Resources/config.yaml" "$OUT/provider.yaml"
cp "$ROOT/packaging/linux/"*.service "$OUT/"
cp "$ROOT/packaging/linux/install.sh" "$OUT/install.sh"
chmod +x "$OUT/install.sh" "$OUT/vibeshare" "$OUT/vibeshare-router" "$OUT/cli-proxy-api"
(cd "$OUT" && shasum -a 256 vibeshare-router vibeshare cli-proxy-api provider.yaml *.service > SHA256SUMS)
echo "Linux bundle: $OUT"
