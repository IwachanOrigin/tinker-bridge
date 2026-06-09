#!/bin/bash

# install.sh - tinker-bridge install script
# How to use : curl -sSL https://github.com/IwachanOrigin/tinker-bridge/releases/latest/download/install.sh | bash

set -e

REPO="IwachanOrigin/tinker-bridge"
INSTALL_DIR="$HOME/.local/share/tinker-bridge"
BIN_DIR="$HOME/.local/bin"
ARCH="$(uname -m)"
OS="$(uname -s | tr '[:upper:]' '[:lower:]')"

# ----- ログ出力 -----
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}{tinker}${NC} $1"; }
warn()  { echo -e "${YELLOW}{tinker}${NC} $1"; }
error() { echo -e "${RED}{tinker}${NC} $1" >&2; exit 1; }

# ----- アーキテクチャ確認 -----
case "$ARCH" in
    x86_64)  ARCH_NAME="x86_64" ;;
    aarch64) ARCH_NAME="aarch64" ;;
    *)       error "サポートされていないアーキテクチャ: $ARCH" ;;
esac

TARBALL="tinker-bridge-${OS}-${ARCH_NAME}.tar.gz"

# ----- 最新バージョンを取得 -----
info "最新バージョンを確認中..."
LATEST=$(curl -sSf "https://api.github.com/repos/${REPO}/releases/latest" \
             | grep '"tag_name"' \
             | sed -E 's/.*"tag_name": *"([^"]+)".*/\1/')

if [ -z "$LATEST" ]; then
    error "バージョン情報を取得できませんでした。"
fi
info "バージョン: $LATEST"

# ----- ダウンロード -----
DOWNLOAD_URL="https://github.com/${REPO}/releases/download/${LATEST}/${TARBALL}"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

info "ダウンロード中: $DOWNLOAD_URL"

if ! curl -sSfL "$DOWNLOAD_URL" -o "$TMP_DIR/$TARBALL"; then
    error "ダウンロードに失敗しました。"
fi

# ----- 解凍 -----
info "展開中..."
tar xzf "$TMP_DIR/$TARBALL" -C "$TMP_DIR"

# ----- インストール -----
mkdir -p "$INSTALL_DIR" "$BIN_DIR"

# 配置して実行権限を付与
cp "$TMP_DIR/tinker-server" "$INSTALL_DIR/"
cp "$TMP_DIR/tinker-bridge" "$INSTALL_DIR/"
chmod +x "$INSTALL_DIR/tinker-server" "$INSTALL_DIR/tinker-bridge"

# tinker.sh -> ~/.local/bin/tinker
cp "$TMP_DIR/tinker.sh" "$BIN_DIR/tinker"

# バイナリパスをINSTALL_DIRに書き換え、実行権限を付与
sed -i "s|INSTALL_DIR=.*|INSTALL_DIR=\"$INSTALL_DIR\"|" "$BIN_DIR/tinker"
chmod +x "$BIN_DIR/tinker"

# ----- PATHの設定 -----
SHELL_RC=""
case "$SHELL" in
    */bash) SHELL_RC="$HOME/.bashrc" ;;
    */zsh)  SHELL_RC="$HOME/.zshrc" ;;
    *)      SHELL_RC="$HOME/.bashrc" ;;
esac

PATH_LINE="export PATH=\"\$HOME/.local/bin:\$PATH\""
if ! grep -qF "$PATH_LINE" "$SHELL_RC" 2>/dev/null; then
    echo "" >> "$SHELL_RC"
    echo "# tinker-bridge" >> "$SHELL_RC"
    echo "$PATH_LINE" >> "$SHELL_RC"
    info "PATH を $SHELL_RC に追加しました。"
fi

# ----- 動作確認 -----
info "動作確認中..."
if "$INSTALL_DIR/tinker-server" --version 2>/dev/null || \
        "$INSTALL_DIR/tinker-server" & sleep 0.5 && kill %1 2>/dev/null; then
    info "tinker-server OK"
fi

# ----- 完了処理 -----
echo ""
echo -e "${GREEN}=========================================${NC}"
echo -e "${GREEN} tinker-bridge $LATEST install finished! ${NC}"
echo -e "${GREEN}=========================================${NC}"
echo ""
info "インストール先: $INSTALL_DIR"
info "コマンド: $BIN_DIR/tinker"
echo ""
warn "新たにターミナルを開くか、以下を実行してPATHを反映してください:"
echo "  source $SHELL_RC"
echo ""
info "使い方:"
echo "  cd /your/project"
echo "  tinker ."
echo ""
info "emacs側の設定 (init.el)"
echo "  (require 'tinker)"
echo "  (tinker-global-mode 1)"
echo "  (tinker-start-notify-server)"



