# brew-fallback — Known Issues

## 1. Archive bottle version mismatch

**Symptom:** `brew install` prints `Error: /usr/local/Cellar/<pkg>/<ver> is not a directory` after trying the archive bottle path.

**Root cause:** Some homebrew-core commits have a Formula url version different from the bottle tarball version. For example, commit `9b3d070` for `fd` has `url=v10.4.0.tar.gz` but the bottle stanza contains sha256 for `fd--10.3.0.ventura.bottle.tar.gz`. brew parses `10.4.0` as the Cellar version from the url, then fails when the tarball unpacks to `10.3.0/`.

**Current behavior (OK):** brew-fallback detects the error, cleans up the mismatched directory, and falls back to MacPorts. User sees: archive attempt → error → MacPorts install → success.

**Fix (pending):** In `__brew_fallback_try_archive_bottle()`, verify Formula url version matches bottle version before selecting the commit. Skip commits like `9b3d070` and continue searching for consistent ones.

**Affected packages observed:** `fd` on ventura (other packages may be affected depending on homebrew-core history).

## 2. Archive bottle build dependency resolution (API mode)

**Symptom:** `brew install homebrew/brew-fallback/<pkg>` may fail with "No available formula with the name 'rust'" even though the bottle does not need compile-time dependencies.

**Root cause:** brew 4.x API mode may not resolve build dependencies (like `depends_on "rust" => :build`) from homebrew-core even when they aren't needed for bottle installation.

**Fix (pending):** Set `HOMEBREW_NO_INSTALL_FROM_API=1` before calling brew from archive path, or ensure local core git repo is available.
