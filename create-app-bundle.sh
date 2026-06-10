#!/bin/bash
# Builds VibeShare.app: compiles the Go router + Swift menu-bar app, assembles
# the bundle, and code-signs (Developer ID if available, else ad-hoc).
set -e

GREEN='\033[0;32m'; BLUE='\033[0;34m'; YELLOW='\033[1;33m'; NC='\033[0m'

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$PROJECT_DIR/src"
ROUTER_DIR="$PROJECT_DIR/router"
RESOURCES_DIR="$SRC_DIR/Sources/Resources"
APP_NAME="VibeShare"
EXEC_NAME="VibeShare"
APP_DIR="$PROJECT_DIR/$APP_NAME.app"

GO_BIN="$(command -v go || echo /opt/homebrew/bin/go)"
# UNIVERSAL=1 builds fat (arm64 + x86_64) binaries that run on both Apple
# Silicon and Intel Macs. Default builds for this machine's architecture only.
UNIVERSAL="${UNIVERSAL:-0}"

# Downloads a cli-proxy-api asset matching $1 (regex) and prints the binary path.
dl_cliproxy() {
  local pat="$1" out="$2"
  local url
  url="$(curl -s -f https://api.github.com/repos/router-for-me/CLIProxyAPI/releases/latest \
    | python3 -c "import sys,json,re;d=json.load(sys.stdin);p=re.compile(r'$pat.*\.tar\.gz\$');print(next(a['browser_download_url'] for a in d['assets'] if p.search(a['name'])))")"
  mkdir -p "$out"; curl -s -L -o "$out/c.tgz" "$url"; tar -xzf "$out/c.tgz" -C "$out"
  find "$out" -type f \( -name 'cli-proxy-api*' -o -name 'CLIProxyAPI*' \) ! -name '*.yaml' ! -name '*.md' | head -1
}

# 1. Provider engine binary.
if [ "$UNIVERSAL" = "1" ]; then
  echo -e "${BLUE}Building universal cli-proxy-api (arm64 + x86_64)...${NC}"
  TMP_CPA="$(mktemp -d)"
  CPA_ARM="$(dl_cliproxy 'darwin_(aarch64|arm64)' "$TMP_CPA/arm")"
  CPA_AMD="$(dl_cliproxy 'darwin_(amd64|x86_64)' "$TMP_CPA/amd")"
  lipo -create "$CPA_ARM" "$CPA_AMD" -output "$RESOURCES_DIR/cli-proxy-api-plus"
  chmod +x "$RESOURCES_DIR/cli-proxy-api-plus"
  rm -rf "$TMP_CPA"
elif [ ! -f "$RESOURCES_DIR/cli-proxy-api-plus" ]; then
  echo -e "${BLUE}Fetching cli-proxy-api...${NC}"
  "$PROJECT_DIR/scripts/fetch-cliproxyapi.sh"
fi

# 2. Build the Go router into Resources.
echo -e "${BLUE}Building vibeshare-router (Go)...${NC}"
rm -f "$RESOURCES_DIR/vibeshare-router" # go build won't overwrite a fat (universal) binary
if [ "$UNIVERSAL" = "1" ]; then
  TMP_GO="$(mktemp -d)"
  ( cd "$ROUTER_DIR" \
      && GOOS=darwin GOARCH=arm64 "$GO_BIN" build -trimpath -o "$TMP_GO/r-arm64" . \
      && GOOS=darwin GOARCH=amd64 "$GO_BIN" build -trimpath -o "$TMP_GO/r-amd64" . )
  lipo -create "$TMP_GO/r-arm64" "$TMP_GO/r-amd64" -output "$RESOURCES_DIR/vibeshare-router"
  rm -rf "$TMP_GO"
else
  ( cd "$ROUTER_DIR" && "$GO_BIN" build -trimpath -o "$RESOURCES_DIR/vibeshare-router" . )
fi
chmod +x "$RESOURCES_DIR/vibeshare-router"
echo -e "${GREEN}✅ router archs: $(lipo -archs "$RESOURCES_DIR/vibeshare-router" 2>/dev/null)${NC}"

# 3. Build the Swift app (release).
echo -e "${BLUE}Building Swift app (release)...${NC}"
if [ "$UNIVERSAL" = "1" ]; then
  ( cd "$SRC_DIR" && swift build -c release --arch arm64 --arch x86_64 )
  BUILD_DIR="$SRC_DIR/.build/apple/Products/Release"
else
  ( cd "$SRC_DIR" && swift build -c release ${TARGET_ARCH:+--arch "$TARGET_ARCH"} )
  BUILD_DIR="$SRC_DIR/.build/release"
fi

# 4. Assemble the .app.
echo -e "${BLUE}Assembling $APP_NAME.app...${NC}"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BUILD_DIR/$EXEC_NAME" "$APP_DIR/Contents/MacOS/"
chmod +x "$APP_DIR/Contents/MacOS/$EXEC_NAME"

# Copy each resource (binaries, config) directly into Contents/Resources.
for item in "$RESOURCES_DIR"/*; do
  [ -e "$item" ] || continue
  case "$item" in *.swift) continue;; esac
  cp -R "$item" "$APP_DIR/Contents/Resources/"
done

cp "$SRC_DIR/Info.plist" "$APP_DIR/Contents/"
echo -n "APPL????" > "$APP_DIR/Contents/PkgInfo"

# Inject version.
VERSION="${APP_VERSION:-$(git -C "$PROJECT_DIR" describe --tags --abbrev=0 2>/dev/null || echo 0.1.0)}"
VERSION="${VERSION#v}"
BUILD_NUMBER="$(git -C "$PROJECT_DIR" rev-list --count HEAD 2>/dev/null || echo 1)"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION}" "$APP_DIR/Contents/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${BUILD_NUMBER}" "$APP_DIR/Contents/Info.plist" 2>/dev/null || true

if [ ! -f "$APP_DIR/Contents/Resources/cli-proxy-api-plus" ] || \
   [ ! -f "$APP_DIR/Contents/Resources/vibeshare-router" ]; then
  echo -e "${YELLOW}⚠️  bundled binaries missing!${NC}"; exit 1
fi

# 5. Sign.
echo -e "${BLUE}Signing...${NC}"
IDENTITY="${CODESIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | grep "Developer ID Application" | head -1 | sed 's/.*"\(.*\)"/\1/')}"
ENT="$PROJECT_DIR/entitlements.plist"
xattr -cr "$APP_DIR" 2>/dev/null || true

if [ -n "$IDENTITY" ]; then
  echo -e "${GREEN}Signing with: $IDENTITY${NC}"
  for bin in cli-proxy-api-plus vibeshare-router; do
    codesign --force --sign "$IDENTITY" --options runtime --timestamp \
      --entitlements "$ENT" "$APP_DIR/Contents/Resources/$bin"
  done
  codesign --force --sign "$IDENTITY" --options runtime --timestamp \
    --entitlements "$ENT" "$APP_DIR/Contents/MacOS/$EXEC_NAME"
  codesign --force --sign "$IDENTITY" --options runtime --timestamp \
    --entitlements "$ENT" "$APP_DIR"
  codesign --verify --deep --strict --verbose=2 "$APP_DIR" && echo -e "${GREEN}✅ verified${NC}"
else
  echo -e "${YELLOW}No Developer ID — ad-hoc signing (fine for local use).${NC}"
  for bin in cli-proxy-api-plus vibeshare-router; do
    codesign --force --sign - --entitlements "$ENT" "$APP_DIR/Contents/Resources/$bin" 2>/dev/null || true
  done
  codesign --force --deep --sign - --entitlements "$ENT" "$APP_DIR"
fi

echo -e "${GREEN}✅ Built $APP_DIR${NC}"
echo "   Drag it to /Applications, or run: open '$APP_DIR'"
