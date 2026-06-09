#!/bin/bash
# Downloads the latest CLIProxyAPI release binary into src/Sources/Resources/
# as `cli-proxy-api-plus` (the provider engine VibeShare bundles).
set -e

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET_DIR="$PROJECT_DIR/src/Sources/Resources"
TARGET_FILE="$TARGET_DIR/cli-proxy-api-plus"
mkdir -p "$TARGET_DIR"

# Pick the asset for this Mac's architecture.
ARCH="$(uname -m)"
case "$ARCH" in
  arm64) PATTERN='darwin_(aarch64|arm64)' ;;
  x86_64) PATTERN='darwin_(amd64|x86_64)' ;;
  *) echo "Unsupported arch: $ARCH" >&2; exit 1 ;;
esac

echo "Fetching latest CLIProxyAPI release for $ARCH..."
JSON="$(curl -s -f https://api.github.com/repos/router-for-me/CLIProxyAPI/releases/latest)"
URL="$(echo "$JSON" | python3 -c "
import sys, json, re
d = json.load(sys.stdin)
pat = re.compile(r'$PATTERN.*\.tar\.gz$')
for a in d['assets']:
    if pat.search(a['name']):
        print(a['browser_download_url']); break
")"

if [ -z "$URL" ]; then
  echo "Could not find a matching darwin asset." >&2
  exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
echo "Downloading $URL"
curl -s -L -o "$TMP/cpa.tar.gz" "$URL"
tar -xzf "$TMP/cpa.tar.gz" -C "$TMP"

BIN="$(find "$TMP" -type f \( -name 'cli-proxy-api*' -o -name 'CLIProxyAPI*' \) ! -name '*.yaml' ! -name '*.md' | head -1)"
if [ -z "$BIN" ]; then
  echo "No binary found in tarball." >&2
  ls -la "$TMP" >&2
  exit 1
fi

cp "$BIN" "$TARGET_FILE"
chmod +x "$TARGET_FILE"
echo "Installed $(ls -lh "$TARGET_FILE" | awk '{print $5}') -> $TARGET_FILE"
