# VibeShare repository instructions

## VibeShare fork installs — one canonical app

- All VibeShare fork updates replace `/Applications/VibeShare.app`, keeping the bundle identifier `com.vibeshare.app`. Never install versioned, renamed, or numbered copies alongside it.
- Use `make install` to replace the installed app, or `make run` to install and open that same copy. Both go through `scripts/install-app.sh`, which MOVES the build into /Applications and deletes every other `com.vibeshare.app` bundle under $HOME (repo builds, Codex work dirs, Release Backups). Never copy `.app` bundles anywhere else — rollback = rebuild from the git commit.
- Quit VibeShare cleanly before replacing it, coordinating around active shared sessions. Preserve `~/.vibeshare` and all existing accounts, grants, connections, and settings.
- VibeProxy is a separate app, not an old VibeShare version. Never remove, replace, or rename it as part of VibeShare cleanup.
- After an authorized install, open `/Applications/VibeShare.app` and verify its running executable path, version, and `vibeshare --json doctor` health.
