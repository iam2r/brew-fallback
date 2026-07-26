#!/bin/bash
# brew-fallback installer
# Usage: curl -fsSL https://raw.githubusercontent.com/iam2r/brew-fallback/main/install.sh | bash

set -e

HF="brew-fallback.sh"
URL="https://raw.githubusercontent.com/iam2r/brew-fallback/main/$HF"

# 检测 shell
detect_shell() {
  if [[ -n "$ZSH_VERSION" ]]; then
    echo "zsh"
  elif [[ -n "$BASH_VERSION" ]]; then
    echo "bash"
  else
    # 从父进程推断
    local parent="$(ps -ocommand= -p $PPID 2>/dev/null | awk '{print $1}')"
    case "$parent" in
      *zsh) echo "zsh" ;;
      *bash) echo "bash" ;;
      *) echo "unknown" ;;
    esac
  fi
}

SHELL_TYPE="${SHELL_TYPE:-$(detect_shell)}"
case "$SHELL_TYPE" in
  zsh)  RCFILE="$HOME/.zshrc" ;;
  bash) RCFILE="$HOME/.bashrc" ; [[ -f "$HOME/.bash_profile" ]] && RCFILE="$HOME/.bash_profile" ;;
  *)
    echo "❌ 无法识别的 shell，请手动添加: source $HF"
    exit 1
    ;;
esac

# 下载脚本
echo "📦 下载 brew-fallback.sh..."
mkdir -p "$HOME/.local/share/brew-fallback"
if curl -fsSL -o "$HOME/.local/share/brew-fallback/$HF" "$URL" 2>/dev/null; then
  echo "   ✅ 下载到 ~/.local/share/brew-fallback/$HF"
else
  # fallback: 复制本地文件（install.sh 同目录下）
  SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
  if [[ -f "$SCRIPT_DIR/$HF" ]]; then
    cp "$SCRIPT_DIR/$HF" "$HOME/.local/share/brew-fallback/$HF"
    echo "   ✅ 从本地复制到 ~/.local/share/brew-fallback/$HF"
  else
    echo "❌ 下载失败，请检查网络连接"
    exit 1
  fi
fi

# 加入 shell rc
SOURCE_LINE="source \"$HOME/.local/share/brew-fallback/$HF\""
if grep -qF "$HF" "$RCFILE" 2>/dev/null; then
  echo "   ✅ 已在 $RCFILE 中"
else
  echo "" >> "$RCFILE"
  echo "# brew-fallback: 自动从 MacPorts 镜像补充缺失的 bottle" >> "$RCFILE"
  echo "$SOURCE_LINE" >> "$RCFILE"
  echo "   ✅ 已添加到 $RCFILE"
fi

echo ""
echo "🎉 brew-fallback 安装完成！"
echo ""
echo "在当前终端生效请执行:"
echo "  source $SOURCE_LINE"
echo ""
echo "然后正常使用 brew install 即可。"
echo ""
echo "卸载: 删掉 $RCFILE 中的 brew-fallback 行即可"