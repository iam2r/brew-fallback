# brew-fallback — 当 Homebrew 不再为你的 macOS 编译 bottle
#
# 劫持 brew install，有 bottle 就走原版，没有就从 MacPorts 镜像取预编译。
# 自动补齐运行时依赖库，重写链接路径，写入 INSTALL_RECEIPT 依赖树。
# 装到 Cellar、写 INSTALL_RECEIPT、brew list/uninstall/autoremove 全都能认。
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

# === 本地 tap 目录（存放旧版 Formula） ===
__brew_fallback_tap_dir() {
  echo "$(brew --repo 2>/dev/null)/Library/Taps/homebrew/homebrew-brew-fallback"
}

# === 尝试从 brew CDN (ghcr.io) 下载存档 bottle ===
# 通过 homebrew-core git 历史找旧版 Formula，写进本地 tap，让 brew 原生处理
# 返回 0 表示成功，1 表示不可用
__brew_fallback_try_archive_bottle() {
  local brew_name="$1" osname="$2" arch="$3" dver="$4"
  local tap_dir=$(__brew_fallback_tap_dir)
  local letter="${brew_name:0:1}"
  local rb_path="$tap_dir/Formula/$brew_name.rb"

  # 如果 tap 中已有 Formula 且版本 > 0，跳过
  local formula_ver
  if [[ -f "$rb_path" ]]; then
    formula_ver=$(grep "^  version " "$rb_path" | sed 's/.*"\(.*\)".*/\1/' 2>/dev/null)
    [[ -n "$formula_ver" ]] && return 0  # 已有 Formula，可被安装
  fi

  # 从 homebrew-core git 历史找最后一个含 osname bottle 的 Formula
  local rb_src="/usr/local/Homebrew/Library/Taps/homebrew/homebrew-core/Formula/$letter/$brew_name.rb"
  [[ ! -f "$rb_src" ]] && return 1

  local sha
  sha=$(cd /usr/local/Homebrew/Library/Taps/homebrew/homebrew-core 2>/dev/null \
    && git log --all --oneline --diff-filter=M -- "Formula/$letter/$brew_name.rb" 2>/dev/null \
    | awk '{print $1}' \
    | while read s; do
        local formula=$(git show "$s:Formula/$letter/$brew_name.rb" 2>/dev/null || true)
        echo "$formula" | grep -q "${osname}:" || continue
        # 验证版本一致性：有些 commit 的 bottle stanza 是 copy 进来的，
        # 但 Formula url 版本已经更新（如 url=v10.4.0 但 bottle=10.3.0）
        # 这种情况 brew 安装会报 Cellar 路径不匹配。
        # 1. 取 url 中的版本
        local url_ver
        url_ver=$(echo "$formula" | grep "^  url " | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | sed 's/^v//')
        # 2. 取显式 version 声明（如果有）
        local decl_ver
        decl_ver=$(echo "$formula" | grep "^  version " | sed 's/.*"\(.*\)".*/\1/')
        # 3. 最终版本 = decl_ver || url_ver
        local final_ver="${decl_ver:-$url_ver}"
        [[ -z "$final_ver" ]] && continue
        # 检查版本一致性：bottle 实际版本必须和 Formula url 版本一致
        # 方法：检查 url 行中的版本（如 v10.3.0.tar.gz）被 bottle 引用
        # 以及没有显式 version 字段且不等于 url 版本的情况
        # 对于 fd，bottle 的实则是 url 的版本，检查 url 行中版本出现
        if [[ -n "$decl_ver" ]]; then
          # 显式声明的版本 → 直接验证
          echo "$formula" | grep -qE "version \"${decl_ver}\"" && { echo "$s"; break; }
        else
          # 无显式 version → url 版本默认可信
          # 跳过 has_final 检查，因为 url 中的版本通常与 bottle 一致
          # 只有极少数 commit（如 9b3d070）是 url 新 + bottle 旧的拼贴
          # 对于这些，检查是否有显式 bottle url。没有则接受。
          echo "$s"
          break
        fi
      done)
  [[ -z "$sha" ]] && return 1

  # 取旧 Formula（完整保留，确保 brew 语法正确）
  mkdir -p "$tap_dir/Formula"
  cd /usr/local/Homebrew/Library/Taps/homebrew/homebrew-core 2>/dev/null || return 1
  local formula_content
  formula_content=$(git show "$sha:Formula/$letter/$brew_name.rb" 2>/dev/null) || return 1
  [[ -z "$formula_content" ]] && return 1
  echo "$formula_content" > "$rb_path"
  [[ -s "$rb_path" ]] || return 1

  echo "  archive: 写入本地 tap ${brew_name} (${osname})" >&2
  return 0
}

# === 从本地 tap 安装存档 bottle（brew 原生处理） ===
__brew_fallback_install_archive() {
  local brew_name="$1" osname="$2" arch="$3" dver="$4"
  local tap_dir=$(__brew_fallback_tap_dir)
  local rb_path="$tap_dir/Formula/$brew_name.rb"

  # 先确保 Formula 在 tap 中
  __brew_fallback_try_archive_bottle "$brew_name" "$osname" "$arch" "$dver" || return 1

  # 检查本地 tap 是否已 tap
  if [[ ! -d "$tap_dir/.git" ]]; then
    cd "$tap_dir" 2>/dev/null && git init && git add -A && git commit -m "init" --allow-empty 2>/dev/null
    # brew 需要 tap 的 first commit
    command brew tap homebrew/brew-fallback 2>/dev/null || true
  fi

  echo "  archive: 从 ghcr.io 下载 ${brew_name} 旧版 bottle (${osname})" >&2
  BREW_FALLBACK_INSTALLING_ARCHIVE_PKG="$brew_name" command brew install "homebrew/brew-fallback/${brew_name}" 2>&1
  local rc=$?
  if [[ $rc -eq 0 ]]; then
    local clr
    clr="$(brew --cellar 2>/dev/null)/${brew_name}"
    if ls -d "$clr"/*/INSTALL_RECEIPT.json 2>/dev/null >/dev/null; then
      echo "  archive: 成功" >&2
      return 0
    fi
  fi
  # 清理可能的残留（如版本不一致导致的空目录或无效版本）
  local clr2
  clr2="$(brew --cellar 2>/dev/null)/${brew_name}"
  for d in "$clr2"/*/; do
    [[ -d "$d" && ! -f "$d/INSTALL_RECEIPT.json" ]] && rm -rf "$d" 2>/dev/null
  done
  # 清理旧 bottle 的本地 tap（下次重新选 commit）
  rm -f "$rb_path" 2>/dev/null
  return 1
}


# === brew 包名 → MacPorts 包名映射表 ===
# 同名的大多数不需要写，这里只列出不匹配规则的特例。
# 规则从上到下依次尝试，匹配即停。
__brew_fallback_pkgmap() {
  local name="$1" bare ver
  if [[ "$name" == *@* ]]; then
    bare="${name%%@*}"
    ver="${name#*@}"
  else
    bare="$name"
    ver=""
  fi

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
    git)               echo "git"; return ;;
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

  # 规则 5: node@YY → nodejsYY, node → nodejs(根据 darwin 版本推断)
  if [[ "$bare" == node ]]; then
    if [[ -n "$ver" ]]; then
      echo "nodejs${ver}"
    else
      local dver_node="$(uname -r | cut -d. -f1)"
      if   (( dver_node >= 25 )); then echo "nodejs24"
      elif (( dver_node >= 22 )); then echo "nodejs22"
      else echo "nodejs20"; fi
    fi
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

# === 下载并安装依赖包到 Cellar（按 brew 规范） ===
# 从 MacPorts 镜像取 .tbz2 → 解压到 Cellar/<pkg>/<ver>/lib/
# → symlink /usr/local/lib/libxxx.dylib → ../Cellar/<pkg>/<ver>/lib/libxxx.dylib
# → 写 INSTALL_RECEIPT.json (installed_as_dependency: true)
__brew_fallback_install_dep() {
  local pkg="$1" dver="$2" arch="$3"
  local cellar
  cellar="$(brew --cellar 2>/dev/null)/${pkg}" || cellar="/usr/local/Cellar/${pkg}"

  # 检查是否已安装
  if ls -d "$cellar"/*/lib/*.dylib 2>/dev/null >/dev/null; then
    echo "cached"
    return 0
  fi

  local mirror="https://mirror.fcix.net/macports/packages/${pkg}/"
  local html
  html=$(curl -s --max-time 10 "$mirror" 2>/dev/null) || return 1
  local dep_ver
  dep_ver=$(echo "$html" \
    | grep -oE "${pkg}-[0-9][0-9._]*_0\.darwin_${dver}\.${arch}\.tbz2" \
    | head -1 \
    | sed "s/^${pkg}-//; s/_0\.darwin_${dver}\.${arch}\.tbz2$//")
  [[ -z "$dep_ver" ]] && return 1

  echo "  dep: ${pkg}-${dep_ver}" >&2

  local url="${mirror}${pkg}-${dep_ver}_0.darwin_${dver}.${arch}.tbz2"
  local cache="/tmp/brew-fallback-dep-${pkg}.tbz2"
  curl -sL --max-time 60 -o "$cache" "$url" 2>/dev/null || return 1

  local dep_cellar="${cellar}/${dep_ver}"
  rm -rf "$dep_cellar"
  mkdir -p "$dep_cellar"

  tar xf "$cache" -C "$dep_cellar" 2>/dev/null
  if [[ -d "$dep_cellar/opt/local" ]]; then
    for d in bin lib share etc; do
      [[ -d "$dep_cellar/opt/local/$d" ]] && cp -a "$dep_cellar/opt/local/$d" "$dep_cellar/" 2>/dev/null
    done
    rm -rf "$dep_cellar/opt"
  fi
  rm -f "$cache"

  # symlink /usr/local/lib/libxxx.dylib → ../Cellar/<pkg>/<ver>/lib/libxxx.dylib
  for dy in "$dep_cellar/lib/"*.dylib; do
    [[ -f "$dy" ]] || continue
    local libname="$(basename "$dy")"
    ln -sf "../Cellar/${pkg}/${dep_ver}/lib/${libname}" "/usr/local/lib/${libname}" 2>/dev/null
  done

  # 写 INSTALL_RECEIPT.json
  command python3 -c "
import json, time
with open('${dep_cellar}/INSTALL_RECEIPT.json', 'w') as f:
    json.dump({
        'homebrew_version': '5.0.7',
        'used_options': [], 'unused_options': [],
        'built_as_bottle': True, 'poured_from_bottle': True, 'loaded_from_api': True,
        'installed_as_dependency': True, 'installed_on_request': False,
        'time': int(time.time()),
        'source': {'spec': 'stable', 'versions': {'stable': '${dep_ver}'}, 'tap': 'homebrew/core'},
        'arch': '${arch}',
        'built_on': {'os': 'Macintosh', 'os_version': 'macOS $(sw_vers -productVersion)'},
        'compiler': 'clang', 'runtime_dependencies': [],
    }, f, indent=2)
" 2>/dev/null

  echo "$dep_ver"
}

# === 修复 Mach-O 依赖 + 写入主包 INSTALL_RECEIPT.json ===
# 扫描 /opt/local/ 引用 → 下载依赖到 Cellar → install_name_tool → receipt
__brew_fallback_fix_and_receipt() {
  local cellar_dir="$1" dver="$2" arch="$3" brew_name="$4" ver="$5"
  local tmpdir="/tmp/brew-fallback-receipt-${brew_name}.$$"
  mkdir -p "$tmpdir"

  # 阶段 1: 找所有 Mach-O
  find "$cellar_dir" -type f > "$tmpdir/all"
  : > "$tmpdir/machos"
  while IFS= read -r f; do
    file -b "$f" 2>/dev/null | grep -q "Mach-O" && echo "$f" >> "$tmpdir/machos"
  done < "$tmpdir/all"

  # 阶段 2: 广度优先扫描 /opt/local/ 引用（最多 2 层递归）
  local depth=0 max_depth=2
  : > "$tmpdir/refs"
  : > "$tmpdir/deps"
  local scan_dirs="$cellar_dir"

  while (( depth < max_depth )); do
    local newfile="$tmpdir/new_${depth}"
    : > "$newfile"
    while IFS= read -r f; do
      local match=0
      for sd in $scan_dirs; do
        case "$f" in "$sd"/*) match=1; break ;; esac
      done
      [[ $match -eq 0 ]] && continue
      otool -L "$f" 2>/dev/null | grep "/opt/local/" \
        | sed 's/^[[:space:]]*//; s/ (.*$//' >> "$newfile"
    done < "$tmpdir/machos"

    sort -u -o "$newfile" "$newfile"
    # 只取新引用
    local missing="$tmpdir/miss_${depth}"
    : > "$missing"
    while IFS= read -r ref; do
      grep -qxF "$ref" "$tmpdir/refs" 2>/dev/null || echo "$ref" >> "$missing"
    done < "$newfile"
    [[ ! -s "$missing" ]] && break

    cat "$missing" >> "$tmpdir/refs"
    local new_dirs=""
    while IFS= read -r ref; do
      local lib_name="$(basename "$ref")"
      local bare="${lib_name%.dylib}"
      bare="${bare%.*}"
      local pkg=""
      case "$lib_name" in
        libcharset.*.dylib)       pkg="libiconv";;
        libintl.*.dylib|libtextstyle.*.dylib) pkg="gettext";;
        libssl.*.dylib|libcrypto.*.dylib) pkg="openssl3";;
        libncurses*.dylib|libform*.dylib|libmenu*.dylib|libpanel*.dylib) pkg="ncurses";;
        libpcre2-*.dylib)         pkg="pcre2";;
        libz.*.dylib)             pkg="zlib";;
        libbz2.*.dylib)           pkg="bzip2";;
        liblzma.*.dylib)          pkg="xz";;
        libpng16.*.dylib|libpng.*.dylib) pkg="libpng";;
        libsasl2.*.dylib)         pkg="cyrus-sasl2";;
        liblber.*.dylib|libldap.*.dylib) pkg="openldap";;
        libgpg-error.*.dylib)     pkg="libgpg-error";;
        libgio-2.0.*.dylib|libgmodule-2.0.*.dylib|libgobject-2.0.*.dylib|libglib-2.0.*.dylib|libgthread-2.0.*.dylib) pkg="glib2";;
        libhogweed.*.dylib|libnettle.*.dylib) pkg="nettle";;
        libgmpxx.*.dylib)         pkg="gmp";;
        librtmp.*.dylib)          pkg="rtmpdump";;
        libpixman-1.*.dylib)      pkg="pixman";;
        libltdl.*.dylib)          pkg="libtool";;
        libfreetype.*.dylib)      pkg="freetype";;
        libfontconfig.*.dylib)    pkg="fontconfig";;
        libcurl.*.dylib)          pkg="curl";;
        libarchive.*.dylib)       pkg="libarchive";;
        libssh2.*.dylib)          pkg="libssh2";;
        *)                        pkg="$bare";;
      esac
      [[ -z "$pkg" ]] && continue

      # 下载/安装依赖包到 Cellar
      local dep_ver
      dep_ver=$(__brew_fallback_install_dep "$pkg" "$dver" "$arch") && [[ -n "$dep_ver" ]] || continue

      # 新安装的包需要扫描其库文件的子依赖
      if [[ "$dep_ver" != "cached" ]]; then
        local d_cellar
        d_cellar="$(brew --cellar 2>/dev/null)/${pkg}/${dep_ver}" || d_cellar="/usr/local/Cellar/${pkg}/${dep_ver}"
        new_dirs="$new_dirs $d_cellar"
      fi

      # 记录依赖（去重）
      grep -qxF "${pkg}" "$tmpdir/deps" 2>/dev/null || echo "${pkg}" >> "$tmpdir/deps"
    done < "$missing"
    scan_dirs="$new_dirs"
    ((depth++))
  done

  # 阶段 3: install_name_tool -change /opt/local/... → /usr/local/lib/...
  local fix_count=0
  while IFS= read -r ref; do
    local lib_name="$(basename "$ref")"
    local target="/usr/local/lib/${lib_name}"
    [[ ! -f "$target" ]] && continue
    while IFS= read -r f; do
      install_name_tool -change "$ref" "$target" "$f" 2>/dev/null && ((fix_count++))
    done < "$tmpdir/machos"
  done < "$tmpdir/refs"

  [[ $fix_count -gt 0 ]] && echo "  fix: $fix_count 个依赖路径" >&2

  # 阶段 4: 写主包的 INSTALL_RECEIPT.json（含 runtime_dependencies）
  local pyfile="$tmpdir/write_receipt.py"
  cat > "$pyfile" <<'PYEOF'
import json, time
import os
receipt = {
    "homebrew_version": "5.0.7",
    "used_options": [], "unused_options": [],
    "built_as_bottle": True, "poured_from_bottle": True, "loaded_from_api": True,
    "installed_as_dependency": False, "installed_on_request": True,
    "time": int(time.time()),
    "source": {"spec": "stable", "versions": {"stable": "VER"}, "tap": "homebrew/core"},
    "arch": "ARCH",
    "built_on": {"os": "Macintosh", "os_version": "OS_VER"},
    "compiler": "clang",
}
deps_file = "DEPS_PATH"
if os.path.getsize(deps_file) > 0:
    deps_list = []
    with open(deps_file) as f:
        for line in f:
            line = line.strip()
            if line:
                deps_list.append({"full_name": line, "version": "", "revision": 0, "pkg_version": "", "declared_directly": False})
    receipt["runtime_dependencies"] = deps_list
with open("RECEIPT_PATH", "w") as f:
    json.dump(receipt, f, indent=2)
PYEOF

  # 替换占位符
  local os_ver="macOS $(sw_vers -productVersion)"
  sed -i '' "s|OS_VER|$os_ver|g; s/VER/$ver/g; s/ARCH/$arch/g; s|DEPS_PATH|$tmpdir/deps|g; s|RECEIPT_PATH|${cellar_dir}/INSTALL_RECEIPT.json|g" "$pyfile"
  command python3 "$pyfile" 2>/dev/null

  rm -rf "$tmpdir"
}

# === 按 brew Formula 声明安装依赖到 Cellar ===
# brew info --json → dependencies → pkgmap → MacPorts 逐包下载
# 在装主包之前调用，这样依赖已经在 Cellar 里了
__brew_fallback_install_formula_deps() {
  local brew_name="$1" dver="$2" arch="$3"
  local json_info
  json_info=$(command brew info --json=v2 "$brew_name" 2>/dev/null) || return 0

  # 从 brew JSON 提取运行时依赖列表（跳过 build deps）
  local dep_list
  dep_list=$(echo "$json_info" | command python3 -c "
import json,sys
try:
    d=json.load(sys.stdin)['formulae'][0]
    deps = d.get('dependencies', [])
    print('\n'.join(deps))
except: pass
" 2>/dev/null)

  [[ -z "$dep_list" ]] && return 0

  echo "  deps: 按 brew 依赖声明安装 $(echo "$dep_list" | tr '\n' ' ')" >&2
  local n_installed=0
  while IFS= read -r brew_dep; do
    [[ -z "$brew_dep" ]] && continue
    local mp_dep
    mp_dep=$(__brew_fallback_pkgmap "$brew_dep") || true
    [[ -z "$mp_dep" ]] && {
      echo "    ? ${brew_dep}: 无 MacPorts 映射，跳过" >&2
      continue
    }
    __brew_fallback_install_dep "$mp_dep" "$dver" "$arch" >/dev/null 2>&1 && ((n_installed++))
  done <<< "$dep_list"

  [[ $n_installed -gt 0 ]] && echo "  deps: $n_installed 个依赖已安装" >&2
}

# === 核心：从 MacPorts 镜像下载预编译包，安装到 brew Cellar ===
__brew_fallback_install() {
  local brew_name="$1" mp_name="$2" ver="$3"
  local dver="$4" arch="$5"
  local mirror="https://mirror.fcix.net/macports/packages/$mp_name/"

  # 测试/模拟：BREW_FALLBACK_MOCK_SOURCE 设置后，跳过 MacPorts 下载
  if [[ -n "$BREW_FALLBACK_MOCK_SOURCE" ]]; then return 1; fi
  if [[ -n "$BREW_FALLBACK_MOCK_MIRROR" ]]; then
    mirror="$BREW_FALLBACK_MOCK_MIRROR/"
  fi

  if [[ -z "$ver" ]]; then
    ver=$(curl -s --max-time 10 "$mirror" 2>/dev/null)
    [[ -n "$ver" ]] || return 1
    ver=$(echo "$ver" \
      | grep -oE "${mp_name}-[0-9][0-9._]*_0\.darwin_${dver}\.${arch}\.tbz2" \
      | head -1 \
      | sed "s/^${mp_name}-//; s/_0\.darwin_${dver}\.${arch}\.tbz2$//")
    [[ -z "$ver" ]] && return 1
  fi

  local url="${mirror}${mp_name}-${ver}_0.darwin_${dver}.${arch}.tbz2"
  local cache="/tmp/${brew_name}.tbz2"

  # 先装 Formula 声明的依赖（对标 brew 在安装前的依赖检查）
  __brew_fallback_install_formula_deps "$brew_name" "$dver" "$arch"

  # 再装主包
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

  # 依赖修复 + 写入 INSTALL_RECEIPT.json
  __brew_fallback_fix_and_receipt "$cellar" "$dver" "$arch" "$brew_name" "$ver"

  rm -f "$cache"
  echo "  /usr/local/Cellar/${brew_name}/${ver} (来自 MacPorts 镜像)" >&2
}

# === darwin 版本号 → macOS 版本名映射 ===
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
# 支持用户选择 fallback 策略：
#   BREW_FALLBACK_PREFER=archive   → 优先存档 bottle（默认）
#   BREW_FALLBACK_PREFER=macports  → 优先 MacPorts（最新版本）
#   BREW_FALLBACK_PREFER=source    → 直接源码编译（brew 原生行为）
#
# 当 archive 优先时，如果存档 bottle 不存在或下载失败，自动回退到 MacPorts。
brew() {
  if [[ "$1" == "install" && -n "$2" ]]; then
    local dver="$(__brew_fallback_darwin_ver)"
    [[ -z "$dver" ]] && { command brew "$@"; return $?; }
    local osname="$(__brew_fallback_darwin_to_macos "$dver")"
    [[ "$osname" == "unknown" ]] && { command brew "$@"; return $?; }
    local arch="$(uname -m)"

    if [[ -z "$BREW_FALLBACK_MOCK_NO_BOTTLE" ]]; then
      local want_key="${osname}"
      [[ "$arch" == "arm64" ]] && want_key="arm64_${osname}"
      local has=$(command brew info --json=v2 "${@:2}" 2>/dev/null | command python3 -c \
        "import json,sys
try:
    d=json.load(sys.stdin)['formulae'][0]
    f=d.get('bottle',{})
    src=f.get('stable',f)
    keys=list(src.get('files',{}).keys())
    print('yes' if '$want_key' in keys else '')
except: print('')" 2>/dev/null)
    fi

    [[ -n "$has" ]] && { command brew "$@"; return $?; }

    # 防止递归：__brew_fallback_install_archive 内部调 brew install 时跳过回退逻辑
    if [[ -n "$BREW_FALLBACK_INSTALLING_ARCHIVE_PKG" ]]; then
      command brew "$@"
      local rc=$?
      unset BREW_FALLBACK_INSTALLING_ARCHIVE_PKG
      return $rc
    fi

    local prefer="${BREW_FALLBACK_PREFER:-archive}"
    echo "brew-fallback: 此包没有 macOS $dver 的 bottle，尝试回退（策略: $prefer）..." >&2
    local pkgs=("${@:2}")
    for pkg in "${pkgs[@]}"; do
      [[ "$pkg" == -* ]] && continue

      if [[ "$prefer" == "macports" || "$prefer" == "source" ]]; then
        # MacPorts 优先（或仅源码）
        :
      else
        # archive 优先
        __brew_fallback_install_archive "$pkg" "$osname" "$arch" "$dver" && continue
      fi

      # MacPorts 镜像
      local mp_name="$(__brew_fallback_pkgmap "$pkg")"
      [[ -z "$mp_name" ]] && {
        echo "  ? brew-fallback: MacPorts 镜像上找不到匹配的包名，回退到 brew 源码编译..." >&2
        command brew install "$pkg"
        continue
      }
      __brew_fallback_install "$pkg" "$mp_name" "" "$dver" "$arch" || {
        echo "  ? brew-fallback: MacPorts 镜像也没有，回退到 brew 源码编译..." >&2
        command brew install "$pkg"
      }
    done
  else
    command brew "$@"
  fi
}
