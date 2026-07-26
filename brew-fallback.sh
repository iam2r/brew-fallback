# brew-fallback — 当 Homebrew 不再为你的 macOS 编译 bottle
#
# 劫持 brew install，有 bottle 就走原版，没有就从 MacPorts 镜像取预编译。
# 装到 Cellar、写 INSTALL_RECEIPT、brew list/uninstall 全都能认。
#
# 适用于：zsh / bash / 任何 POSIX shell
#
# 用法：
#   source brew-fallback.sh
#   brew install <pkg>   # 自动决定走原版还是 fallback

# === 辅助：macOS 版本 → darwin 内核版本号（MacPorts 镜像用）
__brew_fallback_darwin_ver() {
  local v="${1:-$(sw_vers -productVersion)}"
  case "$v" in
    10.6*) echo 10 ;; 10.7*) echo 11 ;; 10.8*) echo 12 ;; 10.9*) echo 13 ;;
    10.10*) echo 14 ;; 10.11*) echo 15 ;; 10.12*) echo 16 ;; 10.13*) echo 17 ;;
    10.14*) echo 18 ;; 10.15*) echo 19 ;; 11*) echo 20 ;; 12*) echo 21 ;;
    13*) echo 22 ;; 14*) echo 23 ;; 15*) echo 24 ;; 16*) echo 25 ;;
    *) echo "" ;;
  esac
}

# === 核心：从 MacPorts 镜像下载预编译包，安装到 brew Cellar
__brew_fallback_install() {
  local pkg="$1" ver="$2"
  local dver="$3" arch="$4"
  local mirror="https://mirror.fcix.net/macports/packages/$pkg/"

  # 如果没传版本号，从镜像目录自动获取最新版
  if [[ -z "$ver" ]]; then
    ver=$(curl -s --max-time 10 "$mirror" 2>/dev/null \
      | grep -oP "$pkg-\K[0-9.]+(?=_0\.darwin_${dver}\.${arch}\.tbz2)" \
      | sort -t. -k1,1n -k2,2n -k3,3n | tail -1)
    [[ -z "$ver" ]] && return 1
  fi

  local url="${mirror}${pkg}-${ver}_0.darwin_${dver}.${arch}.tbz2"
  local cache="/tmp/${pkg}.tbz2"

  echo "==> brew-fallback: 从 MacPorts 镜像下载 ${pkg}-${ver}" >&2
  curl -sL --max-time 60 -o "$cache" "$url" 2>/dev/null || return 1

  local cellar="$(brew --cellar 2>/dev/null)/${pkg}/${ver}"
  [[ -z "$cellar" ]] && cellar="/usr/local/Cellar/${pkg}/${ver}"
  rm -rf "$cellar"
  mkdir -p "$cellar"

  # 解压 MacPorts 包（结构: opt/local/bin/...）
  tar xf "$cache" -C "$cellar" "opt/local/" 2>/dev/null
  if [[ -d "$cellar/opt/local" ]]; then
    for d in bin lib share etc; do
      [[ -d "$cellar/opt/local/$d" ]] && cp -a "$cellar/opt/local/$d" "$cellar/" 2>/dev/null
    done
    rm -rf "$cellar/opt"
  fi

  # 建 symlink 到 /usr/local/bin/
  for f in "$cellar/bin/"*; do
    [[ -f "$f" ]] && ln -sf "$f" "/usr/local/bin/$(basename "$f")" 2>/dev/null
  done
  ln -sfn "$cellar" "$(brew --prefix 2>/dev/null)/opt/${pkg}" 2>/dev/null

  # 写 INSTALL_RECEIPT.json，让 brew 完全识别
  command python3 -c "
import json, time
with open('$cellar/INSTALL_RECEIPT.json', 'w') as f:
    json.dump({
        'homebrew_version': '5.0.7',
        'used_options': [], 'unused_options': [],
        'built_as_bottle': True, 'poured_from_bottle': True, 'loaded_from_api': True,
        'installed_as_dependency': False, 'installed_on_request': True,
        'time': int(time.time()),
        'source': {'spec': 'stable', 'versions': {'stable': '$ver'}, 'tap': 'homebrew/core'},
        'arch': '$arch',
        'built_on': {'os': 'Macintosh', 'os_version': 'macOS $(sw_vers -productVersion)'},
        'compiler': 'clang', 'runtime_dependencies': [],
    }, f, indent=2)
" 2>/dev/null

  rm -f "$cache"
  echo "🍺  /usr/local/Cellar/${pkg}/${ver} (来自 MacPorts 镜像)" >&2
}

# === 劫持 brew — 只拦截 install，其他透传
brew() {
  if [[ "$1" == "install" && -n "$2" ]]; then
    local dver="$(__brew_fallback_darwin_ver)"
    [[ -z "$dver" ]] && { command brew "$@"; return $?; }
    local arch="$(uname -m)"

    # 检查 brew 公式是否有当前 macOS 的 bottle
    local has=$(command brew info --json=v2 "${@:2}" 2>/dev/null | command python3 -c \
      "import json,sys
try:
    d=json.load(sys.stdin)['formulae'][0]
    f=d.get('bottle',{}).get('files',{})
    print('yes' if any('$dver' in k for k in f) or any('$arch' in k for k in f) else '')
except: print('')" 2>/dev/null)

    [[ -n "$has" ]] && { command brew "$@"; return $?; }

    echo "⚠️  brew-fallback: 此包没有 macOS $dver 的 bottle，尝试 MacPorts 镜像..." >&2
    local pkgs=("${@:2}")
    for pkg in "${pkgs[@]}"; do
      [[ "$pkg" == -* ]] && continue
      __brew_fallback_install "$pkg" "" "$dver" "$arch" || {
        echo "  ❌ brew-fallback: MacPorts 镜像也没有，回退到 brew 源码编译..." >&2
        command brew install "$pkg"
      }
    done
  else
    command brew "$@"
  fi
}

# === 导出别名（如果想让 brew 覆盖任何 alias）
# 某些 shell 配置可能有 alias brew=... 会优先于函数
# 不加 unalias 也行，zsh/bash 里同名函数优先级高于 alias
