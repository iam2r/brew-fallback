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

# === darwin 版本号：自动从 uname -r 取 ===
__brew_fallback_darwin_ver() {
  uname -r | cut -d. -f1
}

# === 在 MacPorts 镜像上搜索包名 ===
# 不枚举映射，动态搜索镜像目录，匹配最接近的包名
__brew_fallback_mp_find() {
  local name="$1"

  # 尝试 1: 原名
  local code=$(curl -s --max-time 5 -o /dev/null -w "%{http_code}" \
    "https://mirror.fcix.net/macports/packages/$name/" 2>/dev/null)
  [[ "$code" = "200" ]] && { echo "$name"; return 0; }

  # 尝试 2: 去掉 @version — python@3.12 → python312（去点号）
  if [[ "$name" == *@* ]]; then
    local bare="${name%%@*}"
    local ver="${name#*@}"
    local try="${bare}$(echo "$ver" | tr -d '.')"   # 3.12 → 312
    code=$(curl -s --max-time 5 -o /dev/null -w "%{http_code}" \
      "https://mirror.fcix.net/macports/packages/$try/" 2>/dev/null)
    [[ "$code" = "200" ]] && { echo "$try"; return 0; }
    # 再试裸名（openssl@3 → openssl 而非 openssl3）
    code=$(curl -s --max-time 5 -o /dev/null -w "%{http_code}" \
      "https://mirror.fcix.net/macports/packages/$bare/" 2>/dev/null)
    [[ "$code" = "200" ]] && { echo "$bare"; return 0; }
  fi

  # 尝试 3: node@X → nodejsX
  if [[ "$name" == node@* ]]; then
    local try="nodejs${name#*@}"
    code=$(curl -s --max-time 5 -o /dev/null -w "%{http_code}" \
      "https://mirror.fcix.net/macports/packages/$try/" 2>/dev/null)
    [[ "$code" = "200" ]] && { echo "$try"; return 0; }
  fi

  # 尝试 4: gnu-XXX → gXXX（gnu-sed → gsed）
  if [[ "$name" == gnu-* ]]; then
    local try="g${name#gnu-}"
    code=$(curl -s --max-time 5 -o /dev/null -w "%{http_code}" \
      "https://mirror.fcix.net/macports/packages/$try/" 2>/dev/null)
    [[ "$code" = "200" ]] && { echo "$try"; return 0; }
  fi

  # 尝试 5: sqlite → sqlite3
  if [[ "$name" == sqlite ]]; then
    code=$(curl -s --max-time 5 -o /dev/null -w "%{http_code}" \
      "https://mirror.fcix.net/macports/packages/sqlite3/" 2>/dev/null)
    [[ "$code" = "200" ]] && { echo "sqlite3"; return 0; }
  fi

  # 尝试 6: libXXX → libXXX（直接匹配）
  # 多数 brew 的 libXXX 在 MacPorts 上同名，已经试过原名了

  return 1
}

# === 核心：从 MacPorts 镜像下载预编译包，安装到 brew Cellar ===
__brew_fallback_install() {
  local brew_name="$1" mp_name="$2" ver="$3"
  local dver="$4" arch="$5"
  local mirror="https://mirror.fcix.net/macports/packages/$mp_name/"

  if [[ -z "$ver" ]]; then
    ver=$(curl -s --max-time 10 "$mirror" 2>/dev/null \
      | grep -oP "$mp_name-\K[0-9.]+(?=_0\.darwin_${dver}\.${arch}\.tbz2)" \
      | sort -t. -k1,1n -k2,2n -k3,3n | tail -1)
    [[ -z "$ver" ]] && return 1
  fi

  local url="${mirror}${mp_name}-${ver}_0.darwin_${dver}.${arch}.tbz2"
  local cache="/tmp/${brew_name}.tbz2"

  echo "==> brew-fallback: 从 MacPorts 镜像下载 ${mp_name}-${ver}" >&2
  curl -sL --max-time 60 -o "$cache" "$url" 2>/dev/null || return 1

  local cellar="$(brew --cellar 2>/dev/null)/${brew_name}/${ver}"
  [[ -z "$cellar" ]] && cellar="/usr/local/Cellar/${brew_name}/${ver}"
  rm -rf "$cellar"
  mkdir -p "$cellar"

  tar xf "$cache" -C "$cellar" "opt/local/" 2>/dev/null
  if [[ -d "$cellar/opt/local" ]]; then
    for d in bin lib share etc; do
      [[ -d "$cellar/opt/local/$d" ]] && cp -a "$cellar/opt/local/$d" "$cellar/" 2>/dev/null
    done
    rm -rf "$cellar/opt"
  fi

  for f in "$cellar/bin/"*; do
    [[ -f "$f" ]] && ln -sf "$f" "/usr/local/bin/$(basename "$f")" 2>/dev/null
  done
  ln -sfn "$cellar" "$(brew --prefix 2>/dev/null)/opt/${brew_name}" 2>/dev/null

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
  echo "🍺  /usr/local/Cellar/${brew_name}/${ver} (来自 MacPorts 镜像)" >&2
}

# === 劫持 brew — 只拦截 install，其他透传 ===
brew() {
  if [[ "$1" == "install" && -n "$2" ]]; then
    local dver="$(__brew_fallback_darwin_ver)"
    [[ -z "$dver" ]] && { command brew "$@"; return $?; }
    local arch="$(uname -m)"

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
      local mp_name="$(__brew_fallback_mp_find "$pkg")"
      [[ -z "$mp_name" ]] && {
        echo "  ❌ brew-fallback: MacPorts 镜像上找不到匹配的包名，回退到 brew 源码编译..." >&2
        command brew install "$pkg"
        continue
      }
      __brew_fallback_install "$pkg" "$mp_name" "" "$dver" "$arch" || {
        echo "  ❌ brew-fallback: MacPorts 镜像也没有，回退到 brew 源码编译..." >&2
        command brew install "$pkg"
      }
    done
  else
    command brew "$@"
  fi
}
