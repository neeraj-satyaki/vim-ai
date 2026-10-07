<div align="center">

# ◆ vim-ai

**An AI engineering layer around Vim: automatic code review and a context-aware chat agent beside your editor.**

<sub>Satyaki Solutions Pvt Ltd · *Creating Innovative Impulse* · [satyaki.co.in](https://satyaki.co.in)</sub>

![license](https://img.shields.io/badge/license-MIT-FCA719) ![vim](https://img.shields.io/badge/Vim-9.0%2B-458DFF) ![tmux](https://img.shields.io/badge/tmux-3.x-458DFF) ![status](https://img.shields.io/badge/status-v0.1-FCA719)

</div>

Vim stays the primary coding environment. `vdev` opens a tmux workspace with Vim on the left
and two agents on the right. A **review agent** quietly reviews what you change, and a
**chat agent** already knows which file, function, line and selection you are on.

```text
┌──────────────────────────────────────────────┬────────────────────────┐
│                                              │ ◆ AI review            │
│                                              │  ✖ ERROR line 4        │
│                                              │    Early return makes  │
│                    VIM                       │    the loop unreachable│
│   ✖ 4   return users.length                  ├────────────────────────┤
│   ⚠ 5   for (const user of users) {          │ ◆ AI chat              │
│           ⚠ Sequential awaits …              │ > what's the syntax    │
│                                              │   for Promise.all here?│
└──────────────────────────────────────────────┴────────────────────────┘
          72%                                              28%
```

## Contents
[Architecture](#architecture) · [Install](#install) · [Launch](#launch) · [Auto-review](#auto-review) ·
[Chat](#chat) · [Live edits](#live-edits) · [Vim commands](#vim-commands) · [Mappings](#key-mappings) · [Configuration](#configuration) ·
[Backends and cost](#review-backends-and-cost) · [Troubleshooting](#troubleshooting) · [Logs](#logs) · [Uninstall](#uninstall) · [Limitations](#limitations)

## Architecture

```text
                    vdev [--noai] [project|file]
                              │
              ┌───────────────┴───────────────┐
           AI mode                         --noai
              │                               │
        tmux session (one per project)    plain `vim`, VIM_AI_ENABLED=0
   ┌──────────┼────────────────────┐      (zero AI processes)
  Vim      review pane          chat pane
   │       vim-ai-bridge        Claude Code TUI (or opencode)
   │        ▲   │  headless review per change:     ▲
   │ JSON   │   └─ opencode / claude -p / ollama   │ UserPromptSubmit hook
   │ channel│      (structured JSON, read-only)    │ attaches Vim context
   └────────┘ unix socket ($XDG_RUNTIME_DIR, 0600) │
   │  context.json (debounced) ────────────────────┘
   └◀── navigate {file,line} ◀── vim-ai-goto ◀── chat agent
```

* **Vim plugin** (`plugin/vim_ai.vim`, `autoload/vimai.vim`). Pure Vim 9 script with timers, channels,
  signs, text properties, the quickfix list and popups. Outside an AI session it does nothing: no
  timers, no autocommands, no files, and every `:AI*` command prints *"AI integration is disabled for this session."*
* **Bridge** (`bin/vim-ai-bridge`, Python stdlib only). Runs in the review pane. It owns a private unix
  socket, receives review requests from Vim, builds a small prompt, calls the model, validates the JSON,
  and pushes findings back. Swapping models means changing one function (`run_backend`).
* **Chat agent** (`bin/vim-ai-chat`). A normal interactive Claude Code session started with a hook
  that attaches the live Vim context to every prompt, a bundled plugin of `/explain`-style commands,
  and permission to run `vim-ai-goto` and nothing extra.
* **No keystroke injection.** Navigation from chat is a structured `{"type":"navigate"}` message. A
  trusted Vim handler validates it, then runs `:edit` and `cursor()`.

## Install

Requirements: Vim 9 (`+channel +job +timers +textprop +popupwin`), tmux ≥ 3.0, Python 3, git,
[Claude Code](https://claude.com/claude-code). Recommended: [opencode](https://opencode.ai) for free idle reviews.

```bash
git clone https://github.com/neeraj-satyaki/vim-ai.git
cd vim-ai && ./install.sh
```

The installer:
* checks dependencies
* symlinks the scripts into `~/.local/bin` and the plugin into `~/.vim/{plugin,autoload}`
* creates `~/.config/vim-ai/config.json` only if it is missing
* backs up anything it would replace to `~/.local/share/vim-ai/backups/<timestamp>/`
* runs `vim-ai-doctor`

It never edits your `.vimrc`, `.bashrc` or `.tmux.conf`. All tmux styling is session-scoped.

## Launch

```bash
vdev .                    # AI workspace for the project containing .
vdev ~/projects/api       # another project → its own independent session
vdev src/worker.ts        # open a file; project root auto-detected
vdev --noai .             # Vim only: no tmux, no agents, no model calls
vdev ~/projects/api --noai
vdev --help | --version
```

The project root is the nearest parent containing `.git`, `package.json`, `pyproject.toml`,
`Cargo.toml` or `go.mod`, falling back to the given directory. Each project gets its own tmux session
(`vdev-<name>-<hash>`) and state directory. Running `vdev` again re-attaches. **Quitting Vim closes the
workspace and stops its agents.**

## Auto-review

| Trigger | When | Reviews | Default backend |
|---|---|---|---|
| **Idle** | 1 s after you stop typing (debounced; each keystroke restarts the timer) | lines changed since the last review | opencode (free hosted model) |
| **Save** | `:w` | everything changed in the file vs `git HEAD` (`git diff`-equivalent) + linter output | Claude Sonnet |
| **Diff** | `:AIReviewDiff` | all uncommitted changes (`git diff HEAD`): commit-level review | Claude Sonnet |
| **File** | `:AIReviewFile` | whole file | Claude Sonnet |
| Function exit | leaving a function you changed (opt-in: `review_function_exit`) | as idle | as idle |

What gets sent is deliberately small: the changed lines, the surrounding window (whole file when
under 400 lines), imports, language, cursor, linter diagnostics on save, and project rules. The
reviewer may use read-only `Read/Grep/Glob` to look up a symbol it needs. It never sees `.env`, keys or `~/.ssh`.

**Cost and noise controls**
* debounce
* `min_review_interval_s` cooldown (only the newest pending change runs)
* minimum meaningful change (whitespace edits ignored)
* a hash cache, so identical code is never reviewed twice
* newer edits cancel in-flight reviews
* ignore patterns (`node_modules`, `dist`, `build`, `.next`, `coverage`, `vendor`, `.git`, minified/generated files, lockfiles, `.env`)
* files over `max_file_lines` are skipped

**Stale-result protection.** Every request carries the buffer's `changedtick` and a content hash, and
every finding carries the exact text of its line. If you kept typing while the review ran, each
finding is re-anchored by searching ±30 lines for that text. Findings that can't be anchored are
dropped, and if most are lost the whole result is discarded rather than mis-annotating new code.

**Severity:** `ERROR` (likely bug or security hole) and `WARNING` (real risk) get a gutter sign plus
virtual text under the line. `INSIGHT` gets a sign only. `GOOD` is never shown. **Silence is the
default.** The reviewer prompt bans style nitpicks and praise.

**The cursor never moves on its own.** Findings appear as signs, virtual text, the status line and the
quickfix list. The cursor moves only on `]a`/`[a`, `:AIFindings`, or when you ask the chat agent to show you something.

Per-repository rules: add `.ai-review.md` (or `.claude/review-rules.md`) at the project root and it is
included in every review. See [`examples/ai-review.md`](examples/ai-review.md).

## Chat

The bottom-right pane is a regular Claude Code session (or opencode, set `chat_backend`). Every
message you send automatically carries a `<vim-context>` block: project, git branch, file,
filetype, cursor line and column, current line, enclosing function, visual selection, ±15 lines,
and the current review findings. Plain English works:

```text
> what's the syntax for Promise.all with this?
> explain this line
> why do I need await here?
> where is UserService defined?      # jumps Vim there via vim-ai-goto
> fix this                           # proposes a patch; applies only after you confirm
```

Slash commands: `/explain` `/syntax` `/fix` `/review` `/test` `/security` `/perf` `/types` `/docs` `/current` `/diff`.
To see exactly what the agent receives, run `:AIChatContext` in Vim, or `vim-ai-context` in a shell.

## Live edits

Watch agents change your code as it happens:

* **Auto-reload.** Any file open in Vim that changes on disk reloads within about 1 s, whether the
  change came from the chat agent, opencode, git, a formatter or another editor. Changed lines get a
  gold `▎` marker, and the window scrolls to the first change. If you have **unsaved edits** in that
  file, nothing is overwritten. You get a warning instead (`:e!` loads theirs, `:w` keeps yours).
* **Agent edit feed.** When the chat agent uses Edit/Write, Claude Code hooks snapshot the file before
  and after. The review pane prints a coloured diff, for example `✎ Claude edited src/worker.ts +2 -1`.
* **Files that aren't on screen** open full height in your main editor window, every line of the
  file, with the edited lines highlighted in gold and the view on the first change. Your previous
  file is one `Ctrl-^` away, and unsaved buffers are hidden, never lost. Nothing moves while you are typing.
* **Claude's edits are reviewed too.** After an agent (or any external tool) changes a file, the review
  agent runs a deep review of all uncommitted changes in it, the agent's and yours. Findings appear
  as usual (signs, virtual text, quickfix, `]a`).
* Marks clear when you start typing in that buffer, or with `:AIClear`. Nothing moves while you are in insert mode.

Config: `show_agent_edits`, `agent_edit_follow` (scroll to changes), `agent_edit_open`
(`full` | `split` | `preview` | `none`), `review_agent_edits`, `agent_edit_diff_lines`, `external_change_poll_ms`.

## Vim commands

| Command | Action |
|---|---|
| `:AIReview` | review the current change now (bypasses cooldown) |
| `:AIReviewFile` | review the whole file |
| `:AIReviewDiff` | review all uncommitted changes |
| `:AIFindings` | open the AI findings quickfix list (`:cnext` `:cprev` `:cclose`) |
| `:AIClear` | clear findings and annotations |
| `:AIReviewPause` / `:AIReviewResume` / `:AIReviewToggle` | pause automatic review; chat keeps working |
| `:AIChatContext` | show the context the chat agent receives |
| `:AIWorkspaceDisable` / `:AIWorkspaceEnable` | close or reopen the agent panes at runtime |
| `:AIStatus` | connection / pause / findings summary |

## Key mappings

Only created when the key is unmapped; your existing mappings always win. Change or disable them in config.

| Keys | Action |
|---|---|
| `]a` / `[a` and `<leader>an` / `<leader>ap` | next / previous finding (with a popup explaining it) |
| `<leader>ao` | open findings list |
| `<leader>ac` | clear findings |
| `<leader>ar` | review current change |
| `<leader>at` | toggle auto-review |

The status line shows `[AI: idle]`, `[AI: reviewing…]`, `[AI: 1 error, 2 warnings]`,
`[AI: paused]` or `[AI: offline]`. It is appended to your existing `statusline`.

## Configuration

`~/.config/vim-ai/config.json` overrides [`config/default.json`](config/default.json) key by key.
Common keys:

```json
{
  "idle_review_delay_ms": 1000,
  "min_review_interval_s": 20,
  "auto_review": true, "review_on_idle": true, "review_on_save": true, "review_function_exit": false,
  "idle_backend": "opencode", "deep_backend": "claude", "chat_backend": "claude",
  "opencode_model": "opencode/mimo-v2.6-flash-free",
  "idle_model": "haiku", "deep_model": "sonnet",
  "show_insights": true, "show_virtual_text": true,
  "show_agent_edits": true, "agent_edit_follow": true, "agent_edit_open": "full", "review_agent_edits": true,
  "right_pane_percent": 28, "review_pane_percent": 55,
  "mappings": { "next": "]a", "prev": "[a" },
  "ignore": ["*/node_modules/*", "..."],
  "linters": { "python": [["ruff", "check", "--output-format", "concise", "{file}"]] }
}
```

## Review backends and cost

| Backend | Use | GPU | Cost | Typical latency |
|---|---|---|---|---|
| `opencode` | default for idle reviews; any model opencode supports (free `opencode/*-free` models included) | none | free tier | 15–40 s |
| `claude` | default for save/diff; `claude -p` with JSON-schema output, read-only tools | none | your Claude plan/API | 5–10 s |
| `ollama` | fully local/offline (e.g. `qwen2.5-coder:7b`, ~5.6 GB VRAM while loaded) | yes | free | 3–5 s warm |

> **Privacy:** free hosted models (opencode `*-free`) receive the code you send under their provider's
> terms, which may include logging. For client or confidential code, use `claude` or `ollama` for
> `idle_backend`.

Idle reviews fire often, so they default to the free backend. Raise `min_review_interval_s` or use
`:AIReviewPause` while typing boilerplate.

## Troubleshooting

```bash
vim-ai-doctor              # health check: Vim features, tmux, Claude, backends, plugin, socket, layout
vim-ai-restart review      # restart the review agent (Vim reconnects automatically)
vim-ai-restart chat        # restart the chat agent
vim-ai-restart all         # recreate missing panes
```

* `[AI: offline]` means the review pane isn't running: `vim-ai-restart review`.
* A pane that crashes restarts automatically, but after 3 failures in 2 minutes it stops and waits for Enter (no crash loops).
* Nothing ever breaks Vim. If the bridge, model, network or JSON fail, Vim keeps working and the failure is logged.

## Logs

`~/.local/state/vim-ai/bridge.log` records triggers, starts, completions, skips, cancellations, invalid
responses and stale discards. `vim.log` records Vim-side connection and IPC errors. Both rotate at 1 MB.
Code, prompts and secrets are never logged.

## Uninstall

```bash
./uninstall.sh             # from the repo; removes only the symlinks it created
```

Your config, logs and backups are kept.

## Limitations

* Function detection is a regex heuristic, not an AST. It works well for JS/TS/Python/shell; exotic syntax may miss.
* Idle reviews via free hosted models are slower (15–40 s) than Claude or local models.
* opencode chat can't attach context on every prompt (no hook API), so it runs `vim-ai-context` itself.
* Apply-fix is chat-driven (patch shown first, applied on confirm). There is no one-key apply yet.
* Neovim is not supported (Vim 9 channel/textprop APIs).

## Vim productivity guide

New to the keybindings in the companion `.vimrc` (fzf file finding, project grep, ctags jumps,
running Claude from inside Vim)? See [`vimrc-guide.md`](vimrc-guide.md).

## Development

```bash
python3 tests/test_bridge.py   # bridge self-test (diffing, ignores, validation, JSON recovery)
```

---

<div align="center"><sub>Built by <b>Satyaki Solutions Pvt Ltd</b> · Creating Innovative Impulse · <a href="https://satyaki.co.in">satyaki.co.in</a> · MIT License</sub></div>
