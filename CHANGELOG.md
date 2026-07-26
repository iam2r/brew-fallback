# Changelog

## 1.0.0 (2026-07-26)

Initial release.

### Features

- Intercepts `brew install` via shell function (zsh / bash / POSIX)
- Detects missing bottles by checking `brew info --json` for current macOS darwin version
- Falls back to `mirror.fcix.net/macports/` for prebuilt binaries
- Installs to `/usr/local/Cellar/<pkg>/<ver>/` — standard Homebrew layout
- Writes `INSTALL_RECEIPT.json` — `brew list`, `brew info`, `brew uninstall` all work
- Automatic cleanup of downloaded archives
- Graceful fallback to `brew install --from-source` when neither source has a binary
