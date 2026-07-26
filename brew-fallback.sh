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
# 同名的大多数不需要写，这里只列出不匹配规则的特例。
# 规则从上到下依次尝试，匹配即停。
__brew_fallback_pkgmap() {
  local name="$1" bare ver
  bare="${name%%@*}"
  ver="${name#*@}"

  # 规则 1: 精确匹配特例
  case "$name" in
    ag)                echo "the_silver_searcher"; return ;;
    silver-searcher)   echo "the_silver_searcher"; return ;;
    ImageMagick|imagemagick) echo "ImageMagick"; return ;;
    icu4c)             echo "icu"; return ;;
    pkg-config)        echo "pkgconfig"; return ;;
    sqlite)            echo "sqlite3"; return ;;
    mysql)             echo "mariadb"; return ;;
    make|gmake)        echo "gmake"; return ;;
    # GNU 工具
    gnu-which)         echo "gwhich"; return ;;
    gnu-indent)        echo "gindent"; return ;;
    gnu-time)          echo "gtime"; return ;;
    gnu-tar)           echo "gnutar"; return ;;
    # 语言/框架
    luarocks)          echo "lua-luarocks"; return ;;
    haskell-stack)     echo "stack"; return ;;
    dart)              echo "dart-sdk"; return ;;
    gnupg)             echo "gnupg2"; return ;;
    npm)               echo "npm10"; return ;;
    kubectl)           echo "kubectl-1.32"; return ;;
    maven)             echo "maven3"; return ;;
    ruby)              echo "ruby33"; return ;;
    perl)              echo "perl5.38"; return ;;
    pip)               echo "py-pip"; return ;;
    git)               echo "git" ;;
    # 无映射的 → 规则继续
  esac

  # 规则 2: gnu-XXX → gXXX
  if [[ "$name" == gnu-* ]]; then echo "g${name#gnu-}"; return; fi

  # 规则 3: gcc/gcc@14 → gcc14, llvm/llvm@18 → llvm-18, make → gmake
  if [[ "$bare" == gcc ]]; then
    [[ "$name" == gcc@* ]] && echo "gcc${ver#gcc@}" || echo "gcc14"
    return
  fi
  if [[ "$bare" == llvm ]]; then
    [[ "$name" == llvm@* ]] && echo "llvm-${ver#llvm@}" || echo "llvm-18"
    return
  fi
  if [[ "$bare" == make ]]; then echo "gmake"; return; fi

  # 规则 4: openssl@X → openssl（MacPorts 上叫 openssl，不带版本）
  if [[ "$bare" == openssl ]]; then echo "openssl"; return; fi

  # 规则 5: node@YY → nodejsYY, node → nodejs(当前大版本)
  if [[ "$bare" == node ]]; then
    local darwin_ver="${ver:-$(uname -r | cut -d. -f1)}"
    if   (( darwin_ver >= 25 )); then echo "nodejs24"
    elif (( darwin_ver >= 22 )); then echo "nodejs22"
    else echo "nodejs20"; fi
    return
  fi

  # 规则 6: Xxx@YY → XxxYY（去掉点号，通用版本化名）
  # 特例: perl@5.38 → perl5.38（保留点号）
  if [[ "$name" == *@* ]]; then
    if [[ "$bare" == perl ]]; then
      echo "perl${ver}"; return
    fi
    echo "${bare}$(echo "$ver" | tr -d '.')"
    return
  fi

  # 规则 7: 默认同名
  echo "$bare"
}

# === 核心：从 MacPorts 镜像下载预编译包，安装到 brew Cellar ===
__brew_fallback_install() {
  local brew_name="$1" mp_name="$2" ver="$3"
  local dver="$4" arch="$5"
  local mirror="https://mirror.fcix.net/macports/packages/$mp_name/"

  # 测试/模拟：BREW_FALLBACK_MOCK_SOURCE 设置后，跳过 MacPorts 下载，
  # 直接返回 1 让调用方回退到源码编译。
  # BREW_FALLBACK_MOCK_MIRROR 设置后，用自定义 URL 代替 MacPorts 镜像。
  if [[ -n "$BREW_FALLBACK_MOCK_SOURCE" ]]; then return 1; fi
  if [[ -n "$BREW_FALLBACK_MOCK_MIRROR" ]]; then
    mirror="$BREW_FALLBACK_MOCK_MIRROR/"
  fi

  if [[ -z "$ver" ]]; then
    ver=$(curl -s --max-time 10 "$mirror" 2>/dev/null)
    [[ -n "$ver" ]] || return 1
    # MacPorts 镜像返回 HTML 目录列表，提取 .tbz2 文件链接中的版本号
    ver=$(echo "$ver" \
      | grep -oE "${mp_name}-[0-9][0-9._]*_0\.darwin_${dver}\.${arch}\.tbz2" \
      | head -1 \
      | sed "s/^${mp_name}-//; s/_0\.darwin_${dver}\.${arch}\.tbz2$//")
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

# === darwin 版本号 → macOS 版本名映射 ===
# brew bottle 的 key 用版本名 (sequoia, sonoma...)，不是 darwin 数字
__brew_fallback_darwin_to_macos() {
  case "$1" in
    26) echo "tahoe" ;;
    25) echo "tahoe" ;;
    24) echo "sequoia" ;;
    23) echo "sonoma" ;;
    22) echo "ventura" ;;
    21) echo "monterey" ;;
    20) echo "bigsur" ;;
    19) echo "catalina" ;;
    18) echo "mojave" ;;
    17) echo "high_sierra" ;;
    *) echo "unknown" ;;
  esac
}

# === 劫持 brew — 只拦截 install，其他透传 ===
brew() {
  if [[ "$1" == "install" && -n "$2" ]]; then
    local dver="$(__brew_fallback_darwin_ver)"
    [[ -z "$dver" ]] && { command brew "$@"; return $?; }
    local osname="$(__brew_fallback_darwin_to_macos "$dver")"
    [[ "$osname" == "unknown" ]] && { command brew "$@"; return $?; }
    local arch="$(uname -m)"

    # 测试/模拟：BREW_FALLBACK_MOCK_NO_BOTTLE 设置后，强制所有包走 fallback 路径，
    # 绕过 bottle 检测（模拟老旧 macOS 场景）。
    if [[ -z "$BREW_FALLBACK_MOCK_NO_BOTTLE" ]]; then
      local want_key="${osname}"
      [[ "$arch" == "arm64" ]] && want_key="arm64_${osname}"

      local has=$(command brew info --json=v2 "${@:2}" 2>/dev/null | command python3 -c \
        "import json,sys
try:
    d=json.load(sys.stdin)['formulae'][0]
    f=d.get('bottle',{})
    # brew v4: bottle.stable.files.<key>
    # brew v3: bottle.files.<key>
    src=f.get('stable',f)
    keys=list(src.get('files',{}).keys())
    print('yes' if '$want_key' in keys else '')
except: print('')" 2>/dev/null)
    fi

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
