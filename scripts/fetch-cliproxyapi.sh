#!/bin/bash
# Downloads a PINNED, checksum-verified CLIProxyAPI release into
# src/Sources/Resources/cli-proxy-api-plus (the provider engine VibeShare bundles).
# Usage: fetch-cliproxyapi.sh [arch] [dest]
#   arch  arm64|aarch64 | x86_64|amd64   (default: this machine's arch)
#   dest  output binary path            (default: src/Sources/Resources/cli-proxy-api-plus)
# Bump the engine by editing CLIPROXY_VERSION AND scripts/cliproxyapi.sha256 together.
set -euo pipefail

CLIPROXY_VERSION="${CLIPROXY_VERSION:-7.1.62}"
REPO="router-for-me/CLIProxyAPI"

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUMS_FILE="$PROJECT_DIR/scripts/cliproxyapi.sha256"

ARG_ARCH="${1:-$(uname -m)}"
case "$ARG_ARCH" in
  arm64|aarch64) ASSET_ARCH="darwin_aarch64" ;;
  x86_64|amd64)  ASSET_ARCH="darwin_amd64" ;;
  *) echo "Unsupported arch: $ARG_ARCH" >&2; exit 1 ;;
esac
DEST="${2:-$PROJECT_DIR/src/Sources/Resources/cli-proxy-api-plus}"
mkdir -p "$(dirname "$DEST")"

ASSET="CLIProxyAPI_${CLIPROXY_VERSION}_${ASSET_ARCH}.tar.gz"
URL="https://github.com/${REPO}/releases/download/v${CLIPROXY_VERSION}/${ASSET}"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
echo "Fetching pinned CLIProxyAPI v${CLIPROXY_VERSION} (${ASSET_ARCH})..."
echo "  $URL"
curl -fsSL -o "$TMP/$ASSET" "$URL"

EXPECTED="$(awk -v a="$ASSET" '$2 == a {print $1}' "$SUMS_FILE")"
if [ -z "$EXPECTED" ]; then
  echo "ERROR: no pinned checksum for $ASSET in $SUMS_FILE" >&2; exit 1
fi
ACTUAL="$(shasum -a 256 "$TMP/$ASSET" | awk '{print $1}')"
if [ "$EXPECTED" != "$ACTUAL" ]; then
  echo "ERROR: checksum mismatch for $ASSET — refusing to bundle an unverified binary." >&2
  echo "  expected $EXPECTED" >&2; echo "  actual   $ACTUAL" >&2; exit 1
fi
echo "  ✅ checksum verified"

tar -xzf "$TMP/$ASSET" -C "$TMP"
BIN="$(find "$TMP" -type f \( -name 'cli-proxy-api*' -o -name 'CLIProxyAPI*' \) \
        ! -name '*.tar.gz' ! -name '*.yaml' ! -name '*.md' | head -1)"
if [ -z "$BIN" ]; then echo "No binary found in tarball." >&2; ls -la "$TMP" >&2; exit 1; fi

cp "$BIN" "$DEST"; chmod +x "$DEST"
echo "Installed $(ls -lh "$DEST" | awk '{print $5}') -> $DEST"
