#!/bin/bash
# Run from an extracted, checksum-verified Linux bundle as the target user.
set -euo pipefail
cd "$(dirname "$0")"
sha256sum -c SHA256SUMS
install -d -m 700 "$HOME/.local/lib/vibeshare" "$HOME/.config/vibeshare" "$HOME/.cli-proxy-api" "$HOME/.vibeshare" "$HOME/.config/systemd/user" "$HOME/.local/bin"
install -m 755 cli-proxy-api vibeshare-router vibeshare "$HOME/.local/lib/vibeshare/"
install -m 600 provider.yaml "$HOME/.config/vibeshare/provider.yaml"
install -m 644 vibeshare-provider.service vibeshare-router.service "$HOME/.config/systemd/user/"
ln -sfn "$HOME/.local/lib/vibeshare/vibeshare" "$HOME/.local/bin/vibeshare"
systemctl --user daemon-reload
systemctl --user enable --now vibeshare-provider.service vibeshare-router.service
echo "VibeShare Linux host installed. Run: systemctl --user status vibeshare-router vibeshare-provider"
