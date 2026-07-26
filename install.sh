#!/bin/bash
# brew-fallback installer
# Usage: curl -fsSL https://raw.githubusercontent.com/iam2r/brew-fallback/main/install.sh | bash

set -e

HF="brew-fallback.sh"
URL="https://raw.githubusercontent.com/iam2r/brew-fallback/main/$HF"

# 检测用户默认 shell（而不是 install.sh 运行在哪个 shell 下）
USER_SHELL="$(basename "$SHELL" 2>/dev/null || echo "unknown")"
case "$USER_SHELL" in
  zsh)  RCFILE="${ZDOTDIR:-$HOME}/.zshrc" ;;
  bash)
    # macOS: bash 登录 shell 用 .bash_profile，交互式用 .bashrc
    if [[ -f "$HOME/.bash_profile" ]]; then
      RCFILE="$HOME/.bash_profile"
    else
      RCFILE="$HOME/.bashrc"
    fi
    ;;
  *)
    echo "❌ 不支持的 shell: $USER_SHELL"
    echo "请手动添加以下内容到你的 shell rc 文件:"
    echo "  source \"$HOME/.local/share/brew-fallback/$HF\""
    exit 1
    ;;
esac

# 下载脚本
echo "📦 下载 brew-fallback.sh..."
mkdir -p "$HOME/.local/share/brew-fallback"

if curl -fsSL -o "$HOME/.local/share/brew-fallback/$HF" "$URL" 2>/dev/null; then
  echo "  ✅ $HOME/.local/share/brew-fallback/$HF"
else
  # 离线 fallback: 从 install.sh 同级目录复制
  SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd 2>/dev/null || echo "$PWD")"
  if [[ -f "$SCRIPT_DIR/$HF" ]]; then
    cp "$SCRIPT_DIR/$HF" "$HOME/.local/share/brew-fallback/$HF"
    echo "  ✅ $HOME/.local/share/brew-fallback/$HF (本地)"
  else
    echo "❌ 下载失败，无法访问 $URL"
    echo "   请检查网络后重试，或手动复制 brew-fallback.sh"
    exit 1
  fi
fi

# 加入 shell rc（幂等：已有就不重复追加）
SOURCE_LINE="source \"$HOME/.local/share/brew-fallback/$HF\""
MARKER="### brew-fallback ###"
if grep -qF "$MARKER" "$RCFILE" 2>/dev/null; then
  echo "  ✅ 已在 $RCFILE 中"
else
  {
    echo ""
    echo "$MARKER"
    echo "# 自动从 MacPorts 镜像补充 brew 缺失的 bottle"
    echo "$SOURCE_LINE"
  } >> "$RCFILE"
  echo "  ✅ 已写入 $RCFILE"
fi

echo ""
echo "🎉 brew-fallback 安装完成！"
echo ""
echo "在当前终端中执行以下命令使配置生效:"
echo "  source $RCFILE"
echo ""
echo "之后正常使用 brew install 即可:"
echo "  brew install fd       # 有 bottle → 走 brew"
echo "  brew install ripgrep  # 没有 bottle → 自动走 MacPorts 镜像"
echo ""
echo "卸载: 删除 $RCFILE 中 $MARKER 到 $SOURCE_LINE 之间的内容"
