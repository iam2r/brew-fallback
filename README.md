# brew-fallback

**当 Homebrew 不再为你的 macOS 编译 bottle 时，自动从 MacPorts 镜像获取预编译包。**

[English](#english) · [中文](#chinese)

---

## English

`brew-fallback` intercepts `brew install` and automatically works around missing bottles on older macOS versions.

### How it works

```
brew install <pkg>
  ├─ brew 自身有 bottle？      → 原版 brew install
  ├─ MacPorts 镜像有预编译？    → 下载 → 解压到 Cellar → brew list 能认
  └─ 都没有                    → 回退 brew 源码编译
```

The MacPorts fallback:
1. Fetches the prebuilt `.tbz2` archive from `mirror.fcix.net/macports/`
2. Strips the `opt/local/` prefix, installs to `/usr/local/Cellar/<pkg>/<ver>/`
3. Creates `INSTALL_RECEIPT.json` so `brew list`, `brew info`, `brew uninstall` work normally
4. Creates symlinks in `/usr/local/bin/` and `/usr/local/opt/`
5. Cleans up the temporary archive

### Installation

#### Option 1: Quick install (recommended)

```bash
curl -fsSL https://raw.githubusercontent.com/iam2r/brew-fallback/main/install.sh | bash
```

This adds the hook to your `~/.zshrc` or `~/.bashrc`.

#### Option 2: Manual

```bash
# zsh
echo "source /path/to/brew-fallback.sh" >> ~/.zshrc
source ~/.zshrc

# bash
echo "source /path/to/brew-fallback.sh" >> ~/.bashrc
source ~/.bashrc
```

#### Option 3: Via Homebrew tap (coming soon)

```bash
brew tap iam2r/brew-fallback
brew install brew-fallback
```

### Requirements

- macOS 10.13+ (any version Homebrew still supports or has dropped)
- Homebrew installed
- `curl` and `python3` (pre-installed on macOS)
- Internet access to `mirror.fcix.net`

### How to uninstall

```bash
# Remove from shell config
# Delete the "source brew-fallback.sh" line from ~/.zshrc or ~/.bashrc

# Uninstall packages installed via fallback (optional)
brew uninstall <pkg>
```

### Supported shells

- zsh (tested)
- bash (tested)
- Any POSIX-compatible shell that supports shell functions

### Caveats

- The MacPorts version may differ from the latest Homebrew formula version
- Only packages that exist on both Homebrew and MacPorts are supported
- Runtime dependencies (libraries) are NOT installed — this only works for statically linked or self-contained binaries
- For complex packages (ffmpeg, imagemagick, etc.), the source build fallback is more reliable

### License

MIT / Apache 2.0 dual-licensed

---

## Chinese

`brew-fallback` 劫持 `brew install` 命令，当当前 macOS 版本没有 bottle 时，自动从 MacPorts 镜像拉取预编译包——对 MacPorts 完全无感。

### 工作原理

同英文版。核心是一个 shell 函数包裹 `brew`，只拦截 `install` 子命令，其他全部透传。

### 安装

```bash
curl -fsSL https://raw.githubusercontent.com/iam2r/brew-fallback/main/install.sh | bash
```

或手动添加到 `.zshrc` / `.bashrc`。

### 卸载

删掉 `.zshrc` 里添加的 `source brew-fallback.sh` 行即可。
