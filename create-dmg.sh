#!/bin/bash
# Packages a distributable VibeShare.dmg: assembles VibeShare.app (via
# create-app-bundle.sh), lays it out in a Finder window next to an Applications
# shortcut for drag-to-install, compresses it, and — if a Developer ID is
# available — code-signs the disk image. Optional notarization + stapling.
#
# Usage:
#   ./create-dmg.sh                 # build the app fresh, then package the .dmg
#   REUSE_APP=1 ./create-dmg.sh     # reuse an existing VibeShare.app (skip build)
#   UNIVERSAL=1 ./create-dmg.sh     # build a universal app first, then package
#   NOTARIZE=1 ./create-dmg.sh      # also notarize + staple (needs credentials)
#
# Notarization credentials (only used when NOTARIZE=1), pick one:
#   NOTARY_PROFILE=<name>           # a `notarytool store-credentials` profile, OR
#   APPLE_ID=… TEAM_ID=… APP_PASSWORD=…   # app-specific-password trio
set -euo pipefail

GREEN='\033[0;32m'; BLUE='\033[0;34m'; YELLOW='\033[1;33m'; NC='\033[0m'

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_NAME="VibeShare"
VOL_NAME="$APP_NAME"
APP_DIR="$PROJECT_DIR/$APP_NAME.app"

# State the cleanup trap may need to undo; declared up-front so `set -u` is happy.
STAGE=""; MOUNT_DEV=""; TMP_DMG=""
cleanup() {
  if [ -n "$MOUNT_DEV" ]; then hdiutil detach "$MOUNT_DEV" -force -quiet 2>/dev/null || true; fi
  if [ -n "$STAGE" ]; then rm -rf "$STAGE" || true; fi
  if [ -n "$TMP_DMG" ]; then rm -f "$TMP_DMG" || true; fi
  return 0
}
trap cleanup EXIT

# 1. Build the .app (unless told to reuse an existing bundle). create-app-bundle.sh
#    honors UNIVERSAL / CODESIGN_IDENTITY from the environment, so they flow through.
if [ "${REUSE_APP:-0}" = "1" ] && [ -d "$APP_DIR" ]; then
  echo -e "${BLUE}Reusing existing $APP_NAME.app${NC}"
else
  "$PROJECT_DIR/create-app-bundle.sh"
fi
if [ ! -d "$APP_DIR" ]; then
  echo -e "${YELLOW}⚠️  $APP_NAME.app not found — nothing to package.${NC}"; exit 1
fi

# A universal package must hold a fat binary. Guard against a stale single-arch
# bundle slipping through — e.g. REUSE_APP=1 over an app from a per-arch build.
if [ "${UNIVERSAL:-0}" = "1" ]; then
  ARCHS="$(lipo -archs "$APP_DIR/Contents/MacOS/$APP_NAME" 2>/dev/null || echo unknown)"
  if ! echo "$ARCHS" | grep -q arm64 || ! echo "$ARCHS" | grep -q x86_64; then
    echo -e "${YELLOW}⚠️  UNIVERSAL=1 but $APP_NAME.app is '$ARCHS' (not universal). Rebuild without REUSE_APP=1.${NC}"; exit 1
  fi
fi

# 2. Version → output filename. Read it from the built app so the .dmg name always
#    matches its contents; fall back to the same rule create-app-bundle.sh uses.
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_DIR/Contents/Info.plist" 2>/dev/null || true)"
if [ -z "$VERSION" ]; then
  VERSION="${APP_VERSION:-$(git -C "$PROJECT_DIR" describe --tags --abbrev=0 2>/dev/null || echo 0.1.0)}"
fi
VERSION="${VERSION#v}"
DMG_PATH="$PROJECT_DIR/$APP_NAME-$VERSION.dmg"
rm -f "$DMG_PATH"

# 3. Stage the disk-image contents: the app + a shortcut to /Applications.
echo -e "${BLUE}Staging contents...${NC}"
STAGE="$(mktemp -d)"
cp -R "$APP_DIR" "$STAGE/$APP_NAME.app"
ln -s /Applications "$STAGE/Applications"

# 4. Create a writable image sized to the staged contents.
TMP_DMG="$(mktemp -u).dmg"
hdiutil create -srcfolder "$STAGE" -volname "$VOL_NAME" -fs HFS+ \
  -format UDRW -ov "$TMP_DMG" >/dev/null

# 5. Detach any stale mount of the same volume, then mount ours read-write.
MOUNT_POINT="/Volumes/$VOL_NAME"
if [ -d "$MOUNT_POINT" ]; then
  hdiutil detach "$MOUNT_POINT" -force -quiet 2>/dev/null || true
fi
if [ -d "$MOUNT_POINT" ]; then
  echo -e "${YELLOW}⚠️  $MOUNT_POINT is already mounted and won't detach — unmount it and retry.${NC}"; exit 1
fi
echo -e "${BLUE}Laying out the Finder window...${NC}"
MOUNT_DEV="$(hdiutil attach -readwrite -noverify -noautoopen "$TMP_DMG" \
  | grep -E '^/dev/' | head -1 | awk '{print $1}' || true)"
if [[ ! "$MOUNT_DEV" =~ ^/dev/disk[0-9] ]] || [ ! -d "$MOUNT_POINT" ]; then
  echo -e "${YELLOW}⚠️  Failed to mount the image (device='$MOUNT_DEV').${NC}"; exit 1
fi

# Position the icons for drag-to-install. Best-effort: needs a GUI Finder, so a
# headless/SSH run just gets a plain (still valid) image.
osascript <<EOF 2>/dev/null || echo -e "${YELLOW}   (skipped icon layout — no GUI Finder)${NC}"
tell application "Finder"
  tell disk "$VOL_NAME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, 720, 460}
    set theViewOptions to the icon view options of container window
    set arrangement of theViewOptions to not arranged
    set icon size of theViewOptions to 96
    set position of item "$APP_NAME.app" of container window to {140, 170}
    set position of item "Applications" of container window to {380, 170}
    update without registering applications
    delay 1
    close
  end tell
end tell
EOF

sync
# Detach now; clear MOUNT_DEV only on success so the trap can retry a busy device.
if hdiutil detach "$MOUNT_DEV" -quiet 2>/dev/null; then
  MOUNT_DEV=""
else
  sleep 1
  hdiutil detach "$MOUNT_DEV" -force -quiet && MOUNT_DEV="" || true
fi

# 6. Convert to a compressed, read-only image.
echo -e "${BLUE}Compressing...${NC}"
hdiutil convert "$TMP_DMG" -format UDZO -imagekey zlib-level=9 -o "$DMG_PATH" >/dev/null

# 7. Code-sign the disk image with a Developer ID, if one is available.
IDENTITY="${CODESIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null \
  | grep "Developer ID Application" | head -1 | sed 's/.*"\(.*\)"/\1/' || true)}"
if [ -n "$IDENTITY" ]; then
  echo -e "${BLUE}Signing image with: $IDENTITY${NC}"
  codesign --force --sign "$IDENTITY" --timestamp "$DMG_PATH"
  codesign --verify --verbose=2 "$DMG_PATH" && echo -e "${GREEN}✅ image signature verified${NC}"
else
  echo -e "${YELLOW}No Developer ID — leaving the image unsigned (fine for local use).${NC}"
fi

# 8. Optional: notarize with Apple and staple the ticket so it opens with no
#    Gatekeeper prompt on other Macs. Requires a signed app + signed image.
if [ "${NOTARIZE:-0}" = "1" ]; then
  if [ -z "$IDENTITY" ]; then
    echo -e "${YELLOW}⚠️  NOTARIZE=1 but the image is unsigned — skipping notarization.${NC}"
  else
    echo -e "${BLUE}Submitting to Apple notary service (this can take a few minutes)...${NC}"
    if [ -n "${NOTARY_PROFILE:-}" ]; then
      xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
    elif [ -n "${APPLE_ID:-}" ] && [ -n "${TEAM_ID:-}" ] && [ -n "${APP_PASSWORD:-}" ]; then
      xcrun notarytool submit "$DMG_PATH" \
        --apple-id "$APPLE_ID" --team-id "$TEAM_ID" --password "$APP_PASSWORD" --wait
    else
      echo -e "${YELLOW}⚠️  No notary credentials (set NOTARY_PROFILE, or APPLE_ID/TEAM_ID/APP_PASSWORD).${NC}"
      exit 1
    fi
    xcrun stapler staple "$DMG_PATH"
    echo -e "${GREEN}✅ notarized + stapled${NC}"
  fi
fi

echo -e "${GREEN}✅ Built $DMG_PATH${NC}"
echo "   $(du -h "$DMG_PATH" | cut -f1) — open it and drag $APP_NAME to Applications."
