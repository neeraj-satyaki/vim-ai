# Vim productivity guide (~/.vimrc)

Leader key = `\` (default, unset in this vimrc).

## Find files / lines / tags (fzf)
| Key | Does |
|---|---|
| `Ctrl-p` | fuzzy find + open a file |
| `\b` | fuzzy find + switch to an open buffer |
| `\l` | fuzzy find a line in current file |
| `\t` | fuzzy find a tag (function/class) — needs `ctags -R .` run once |

Type to filter, arrows/`Ctrl-j`/`Ctrl-k` to move, `Enter` to open, `Ctrl-t`/`Ctrl-v`/`Ctrl-x` open in new tab/vsplit/split.

## Search code across project (grep)
| Key | Does |
|---|---|
| `\g` | `:Rg <pattern>` — fast grep (needs `ripgrep`: `sudo apt install ripgrep`) |
| `\/` | `:Grep <pattern>` — grep, works even without ripgrep, fills quickfix |
| `\*` | grep whole project for the word under cursor |
| `]q` / `[q` | next/prev match in quickfix list |
| `\q` | reopen quickfix window |
| `\<space>` | clear search highlight |

Workflow: `\g` a term → list of matches opens → `Enter` on a line jumps there → `]q`/`[q` to walk through the rest.

## Browse files/folders
| Key | Does |
|---|---|
| `\e` | open file tree (netrw) in current window |

Inside tree: `Enter` open, `-` go up a dir, `%` new file, `d` new dir.

## Jump to definition
1. Once per project: `ctags -R .` in the project root (needs `universal-ctags`).
2. `\d` on a symbol → jumps to its definition.
3. `\o` → jump back to where you came from.

## Run shell commands / Claude from inside Vim
| Key | Does |
|---|---|
| `\rr<cmd><Enter>` | run any shell command in a terminal split (e.g. `\rr npm test`) |
| `\ca` | open terminal, ask Claude to explain the current file |
| visual-select code, then `\cc` | pipe the selection into `claude` |
| `Esc` (inside a terminal split) | leave terminal mode, back to normal Vim |

## Misc
- Statusline always shows file path + line/col.
- Undo history persists across closing/reopening a file.
- New splits open below/right (predictable).
- `set number relativenumber` — relative line numbers make `5j` / `3k` jumps easy to count.

## Typical loop
1. `Ctrl-p` → open the file you think has the bug.
2. `\*` on a symbol → see every place it's used, project-wide.
3. `\d` → jump straight to its definition.
4. Edit.
5. Visual-select the changed block, `\cc` → ask Claude to sanity-check it.
6. `\rr <test command>` → run tests without leaving Vim.
