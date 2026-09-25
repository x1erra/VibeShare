#!/bin/bash
# Keeps Little Snitch from ever blocking an installed VibeShare.app.
#
# VibeShare is ad-hoc signed (no Team ID), so Little Snitch pins each bundled
# binary to its exact cdHash. Every rebuild changes those hashes, the pins stop
# matching, and silent mode turns the resulting alerts into deny/suggestion
# rules (e.g. cli-proxy-api-plus -> anthropic.com "until quit"). This script:
#   1. sets the four VibeShare binaries to "No identity check" (path only), so
#      rebuilds never invalidate the existing allow rules, and
#   2. removes any deny/suggestion rules Little Snitch created for VibeShare.
# The pre-change model is saved next to the patched one for rollback.
#
# Usage: littlesnitch-sync.sh [app path]   (default: /Applications/VibeShare.app)
# No-op when Little Snitch is not installed or passwordless sudo is unavailable.
set -euo pipefail

APP="${1:-/Applications/VibeShare.app}"
LS_BIN="/Applications/Little Snitch.app/Contents/Components/littlesnitch"
BACKUP_DIR="$HOME/Library/Application Support/VibeShare/Little Snitch Backups"

[ -x "$LS_BIN" ] || exit 0
if ! sudo -n true 2>/dev/null; then
  echo "⚠️  Little Snitch sync skipped (needs passwordless sudo). Run: sudo -v && $0"
  exit 0
fi

mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"
stamp="$(date +%Y%m%d-%H%M%S)"
before="$BACKUP_DIR/model-$stamp.json"
after="$BACKUP_DIR/model-$stamp-synced.json"
sudo -n "$LS_BIN" export-model > "$before"
chmod 600 "$before"

changed="$(python3 - "$APP" "$before" "$after" <<'PY'
import json, sys
app, src, dst = sys.argv[1].rstrip("/"), sys.argv[2], sys.argv[3]
model = json.load(open(src))
contents = app + "/Contents/"
binaries = [contents + p for p in (
    "MacOS/VibeShare",
    "Resources/vibeshare",
    "Resources/vibeshare-router",
    "Resources/cli-proxy-api-plus",
)]

changed = 0
reqs = model.setdefault("codeRequirements", {})
for path in binaries:
    if reqs.get(path) != {"type": "none"}:
        reqs[path] = {"type": "none"}
        changed += 1

def is_vibeshare(rule):
    for key in ("process", "via"):
        value = str(rule.get(key, ""))
        if value.startswith("path."):
            value = "/" + value[len("path."):]
        if value.startswith(contents):
            return True
    return False

rules = model.get("rules", [])
kept = [r for r in rules if not (is_vibeshare(r) and r.get("action") in ("deny", "suggestion"))]
changed += len(rules) - len(kept)
model["rules"] = kept

json.dump(model, open(dst, "w"))
print(changed)
PY
)"

if [ "$changed" = "0" ]; then
  rm -f "$after"
  echo "✅ Little Snitch already allows VibeShare (no changes)"
  exit 0
fi
chmod 600 "$after"
sudo -n "$LS_BIN" restore-model -t "$after" >/dev/null
echo "✅ Little Snitch synced for VibeShare ($changed changes; backup: $before)"
