#!/usr/bin/env bash
# Remove vim-ai symlinks. Keeps ~/.config/vim-ai (your config), logs and backups.
set -euo pipefail
REPO="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
BIN="${VIM_AI_BIN_DIR:-$HOME/.local/bin}"
VIMDIR="${VIM_AI_VIM_DIR:-$HOME/.vim}"
for dst in "$BIN"/vdev "$BIN"/vim-ai-* "$VIMDIR/plugin/vim_ai.vim" "$VIMDIR/autoload/vimai.vim"; do
  if [ -L "$dst" ] && [[ "$(readlink -f "$dst")" == "$REPO"/* ]]; then rm -f "$dst"; echo "removed $dst"; fi
done
echo "Kept: ~/.config/vim-ai, ~/.local/state/vim-ai (logs), ~/.local/share/vim-ai/backups."
echo "Restore a backup with: cp -a ~/.local/share/vim-ai/backups/<timestamp>/<file> <original path>"
