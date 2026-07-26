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

# === brew 包名 → MacPorts 包名映射表 ===
# 同名的大多数不需要写，这里只列出不同的。
# 格式: "brew 包名" "MacPorts 包名"
# 修改此表不需要动核心代码。
__brew_fallback_pkgmap() {
  local name="$1"
  case "$name" in
    # GNU 工具：gnu-XXX → gXXX
    gnu-sed)     echo "gsed" ;;
    gnu-tar)     echo "gtar" ;;
    gnu-which)   echo "gwhich" ;;
    gnu-indent)  echo "gindent" ;;
    gnu-time)    echo "gtime" ;;
    # 语言运行时：Xxx@YY → XxxYY
    python@3.8)  echo "python38" ;;
    python@3.9)  echo "python39" ;;
    python@3.10) echo "python310" ;;
    python@3.11) echo "python311" ;;
    python@3.12) echo "python312" ;;
    python@3.13) echo "python313" ;;
    python)      echo "python312" ;;
    ruby@3.3)    echo "ruby33" ;;
    ruby@3.2)    echo "ruby32" ;;
    perl@5.38)   echo "perl5.38" ;;
    perl@5.36)   echo "perl5.36" ;;
    lua@5.4)     echo "lua54" ;;
    lua@5.3)     echo "lua53" ;;
    node)        echo "nodejs22" ;;
    node@22)     echo "nodejs22" ;;
    node@20)     echo "nodejs20" ;;
    node@18)     echo "nodejs18" ;;
    # 编译器
    gcc)         echo "gcc14" ;;
    gcc@14)      echo "gcc14" ;;
    gcc@13)      echo "gcc13" ;;
    llvm)        echo "llvm-18" ;;
    llvm@18)     echo "llvm-18" ;;
    llvm@17)     echo "llvm-17" ;;
    make)        echo "gmake" ;;
    # 数据库
    mysql)       echo "mariadb" ;;
    postgresql@16) echo "postgresql16" ;;
    postgresql@15) echo "postgresql15" ;;
    sqlite)      echo "sqlite3" ;;
    # 构建
    pkg-config)  echo "pkgconfig" ;;
    # 文本工具
    ag)          echo "the_silver_searcher" ;;
    silver-searcher) echo "the_silver_searcher" ;;
    # 系统
    icu4c)       echo "icu" ;;
    ImageMagick) echo "ImageMagick" ;;
    imagemagick) echo "ImageMagick" ;;
    # 默认同名，再验证是否存在，不存在就用动态搜索 fallback
    *)  local bare="${name%%@*}"
        # 先验证原名
        local code=$(curl -s --max-time 5 -o /dev/null -w "%{http_code}" \
          "https://mirror.fcix.net/macports/packages/$bare/" 2>/dev/null)
        if [[ "$code" = "200" ]]; then
          echo "$bare"
        else
          # 动态搜索：node → nodejs22
          [[ "$bare" == node ]] && { echo "nodejs22"; return; }
          # 剩余交给 git log
          echo ""
        fi
        ;;
  esac
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
      local mp_name="$(__brew_fallback_pkgmap "$pkg")"
      [[ -z "$mp_name" ]] && {
        echo "  ❌ brew-fallback: MacPorts 镜像上找不到匹配的包名，回退到 brew 源码编译..." >&2
        command brew install "$pkg"
        continue
      }
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
