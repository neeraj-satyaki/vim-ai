#!/usr/bin/env bash
# vim-ai installer (Satyaki Solutions). Idempotent; never overwrites your dotfiles.
# - symlinks scripts into ~/.local/bin and the Vim plugin into ~/.vim
# - creates ~/.config/vim-ai/config.json only if missing
# - backs up anything it would replace that isn't already ours
set -euo pipefail
REPO="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
BIN="${VIM_AI_BIN_DIR:-$HOME/.local/bin}"
VIMDIR="${VIM_AI_VIM_DIR:-$HOME/.vim}"
CONF="$HOME/.config/vim-ai"
BACKUP="$HOME/.local/share/vim-ai/backups/$(date +%Y%m%d-%H%M%S)"

say() { printf '\033[38;2;252;167;25m◆\033[0m %s\n' "$*"; }
need() { command -v "$1" >/dev/null || { echo "missing dependency: $1 ($2)"; missing=1; }; }

missing=0
need vim "sudo apt install vim"; need tmux "sudo apt install tmux"; need python3 "sudo apt install python3"
need git "sudo apt install git"
command -v claude >/dev/null || echo "note: Claude Code not found — install it for chat/deep reviews (https://claude.com/claude-code)"
command -v opencode >/dev/null || [ -x "$HOME/.opencode/bin/opencode" ] || echo "note: opencode not found — idle reviews use it by default (curl -fsSL https://opencode.ai/install | bash), or set \"idle_backend\": \"claude\" in $CONF/config.json"
[ "$missing" = 0 ] || exit 1
vim --version | grep -q '+channel' && vim --version | grep -q '+textprop' || { echo "your vim lacks +channel/+textprop (need Vim 9)"; exit 1; }

link() { # src dst
  local src="$1" dst="$2"
  mkdir -p "$(dirname "$dst")"
  if [ -L "$dst" ] && [ "$(readlink -f "$dst")" = "$(readlink -f "$src")" ]; then return; fi
  if [ -e "$dst" ] || [ -L "$dst" ]; then
    mkdir -p "$BACKUP"; cp -a "$dst" "$BACKUP/"; say "backed up $dst -> $BACKUP/"
    rm -f "$dst"
  fi
  ln -s "$src" "$dst"; say "linked $dst"
}

chmod +x "$REPO"/bin/* "$REPO/install.sh" "$REPO/uninstall.sh"
for b in "$REPO"/bin/*; do [ -f "$b" ] && [ -x "$b" ] && link "$b" "$BIN/$(basename "$b")"; done
link "$REPO/plugin/vim_ai.vim" "$VIMDIR/plugin/vim_ai.vim"
link "$REPO/autoload/vimai.vim" "$VIMDIR/autoload/vimai.vim"

mkdir -p "$CONF" "${XDG_STATE_HOME:-$HOME/.local/state}/vim-ai"
if [ ! -f "$CONF/config.json" ]; then
  python3 - "$REPO/config/default.json" "$CONF/config.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
keys = ["auto_review", "review_on_idle", "review_on_save", "review_function_exit", "idle_review_delay_ms",
        "min_review_interval_s", "idle_backend", "deep_backend", "opencode_model", "chat_backend", "idle_model", "deep_model",
        "show_insights", "show_virtual_text", "right_pane_percent", "review_pane_percent"]
json.dump({k: d[k] for k in keys}, open(sys.argv[2], "w"), indent=2)
PY
  say "created $CONF/config.json (overrides; full list of keys: $REPO/config/default.json)"
fi

case ":$PATH:" in *":$BIN:"*) ;; *) echo "note: add $BIN to PATH, e.g. echo 'export PATH=\"$BIN:\$PATH\"' >> ~/.bashrc";; esac
say "installed. Health check:"
"$BIN/vim-ai-doctor" || true
