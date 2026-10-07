" vim-ai autoload — loaded only in AI mode (see plugin/vim_ai.vim).
" Vim <-> bridge: JSON channel over $VIM_AI_SESSION_DIR/bridge.sock.
" Never moves the cursor unless the user asks (]a/[a, :AIFindings, chat navigate).

let s:ch = 0
let s:findings = {}        " abs file -> [finding]
let s:state = 'connecting' " connecting|idle|reviewing|error|offline
let s:paused = 0
let s:ws_off = 0
let s:idle_timer = -1
let s:ctx_timer = -1
let s:last_ctx = ''
let s:last_try = 0
let s:qfid = 0
let s:pending_nav = {}
let s:last_sel = {}
let s:last_func = {}
let s:branch = {}
let s:log_n = 0
let s:fcs_old = {}         " bufnr -> lines before an on-disk change
let s:agent_files = {}     " file -> agent edit msg awaiting reload
let s:recent_agent = {}    " file -> localtime() of last agent edit
let s:deferred_edits = []
let s:state_dir = (empty($XDG_STATE_HOME) ? $HOME . '/.local/state' : $XDG_STATE_HOME) . '/vim-ai'
let s:sev = {'ERROR': ['E', '✖', 'VimAIError'], 'WARNING': ['W', '⚠', 'VimAIWarn'],
      \ 'INSIGHT': ['I', 'ℹ', 'VimAIInfo'], 'GOOD': ['I', '✓', 'VimAIInfo']}

" ------------------------------------------------------------------ setup --
function! vimai#setup() abort
  let s:dir = $VIM_AI_SESSION_DIR
  let s:cfg = s:load_config()
  let s:ignore_re = map(copy(get(s:cfg, 'ignore', [])), 'glob2regpat(v:val)')
  call s:highlights()
  for [name, v] in items(s:sev)
    call sign_define('VimAI' . name, {'text': v[1], 'texthl': v[2] . 'Sign', 'numhl': v[2] . 'Sign'})
    call sign_define('VimAI' . name . 'Range', {'numhl': v[2] . 'Sign'})
    if empty(prop_type_get('VimAIVirt' . name))
      call prop_type_add('VimAIVirt' . name, {'highlight': v[2] . 'Virt'})
    endif
  endfor
  call sign_define('VimAIEdit', {'text': '▎', 'texthl': 'VimAIEditSign', 'linehl': 'VimAIEditLine'})
  if empty(prop_type_get('VimAIEditProp'))
    " text-prop highlight survives on lines where a review sign outranks the edit sign
    call prop_type_add('VimAIEditProp', {'highlight': 'VimAIEditLine', 'priority': -10})
  endif
  augroup vimai
    autocmd!
    " vim-ai reloads changed files itself (same auto-reload as 'autoread', plus change
    " marks); buffer-local so the user's global setting is untouched.
    autocmd BufReadPost,BufNewFile * setlocal noautoread
    autocmd FileChangedShell * call s:on_fcs()
    autocmd FileChangedShellPost * call s:on_fcs_post()
    autocmd InsertEnter * call s:clear_edit_marks(bufnr())
    autocmd TextChanged,TextChangedI,TextChangedP * call s:on_change()
    autocmd CursorMoved,CursorMovedI * call s:on_move()
    autocmd BufWritePost * call s:on_save()
    autocmd BufEnter * call s:on_enter()
    autocmd ModeChanged * if v:event.old_mode =~# '^[vV\x16]' | call timer_start(0, {-> s:save_selection()}) | endif
    autocmd InsertLeave * call s:flush_nav() | call s:flush_edits() | if b:changedtick != get(b:, 'vimai_seen_tick', -1) | call s:on_change() | endif
    autocmd ColorScheme * call s:highlights()
    autocmd VimLeavePre * call s:disconnect()
  augroup END
  if get(s:cfg, 'default_mappings', 1)
    call s:map('next', ':call vimai#jump(1)<CR>')
    call s:map('prev', ':call vimai#jump(-1)<CR>')
    call s:map('next_alt', ':call vimai#jump(1)<CR>')
    call s:map('prev_alt', ':call vimai#jump(-1)<CR>')
    call s:map('open', ':AIFindings<CR>')
    call s:map('clear', ':AIClear<CR>')
    call s:map('review', ':AIReview<CR>')
    call s:map('toggle', ':AIReviewToggle<CR>')
  endif
  if empty(&statusline)
    set statusline=%<%f\ %h%m%r%=%{VimAIStatus()}\ \ %-14.(%l,%c%V%)\ %P
  elseif &statusline !~# 'VimAIStatus'
    let &statusline .= ' %{VimAIStatus()}'
  endif
  for b in getbufinfo({'bufloaded': 1})
    call setbufvar(b.bufnr, '&autoread', 0)
  endfor
  if get(s:cfg, 'external_change_poll_ms', 1000) > 0
    call timer_start(s:cfg.external_change_poll_ms, {-> s:poll()}, {'repeat': -1})
  endif
  call s:connect_retry(20)
endfunction

function! s:load_config() abort
  let defaults = {'auto_review': 1, 'review_on_idle': 1, 'review_on_save': 1,
        \ 'review_function_exit': 0, 'idle_review_delay_ms': 2500, 'context_write_delay_ms': 400,
        \ 'max_file_lines': 6000, 'show_virtual_text': 1, 'stale_search_window': 30,
        \ 'default_mappings': 1, 'mappings': {}, 'ignore': []}
  try
    return extend(defaults, json_decode(join(readfile(s:dir . '/config.json'), "\n")))
  catch
    call s:log('config load failed: ' . v:exception)
    return defaults
  endtry
endfunction

function! s:highlights() abort
  hi default VimAIErrorSign ctermfg=203 guifg=#e06c75
  hi default VimAIWarnSign  ctermfg=214 guifg=#e5a50a
  hi default VimAIInfoSign  ctermfg=74  guifg=#56b6c2
  hi default VimAIErrorVirt ctermfg=203 cterm=italic guifg=#e06c75 gui=italic
  hi default VimAIWarnVirt  ctermfg=214 cterm=italic guifg=#e5a50a gui=italic
  hi default VimAIInfoVirt  ctermfg=244 cterm=italic guifg=#7f848e gui=italic
  hi default VimAIEditSign  ctermfg=214 guifg=#FCA719
  hi default VimAIEditLine  ctermbg=58 guibg=#4a3b10
endfunction

function! s:map(key, rhs) abort
  let lhs = get(get(s:cfg, 'mappings', {}), a:key, '')
  if empty(lhs) || !empty(maparg(lhs, 'n'))
    return  " never override an existing mapping
  endif
  execute 'nnoremap <silent> ' . lhs . ' ' . a:rhs
endfunction

" -------------------------------------------------------------- logging ----
function! s:log(msg) abort
  try
    let f = s:state_dir . '/vim.log'
    if !isdirectory(s:state_dir) | call mkdir(s:state_dir, 'p') | endif
    let s:log_n += 1
    if s:log_n % 100 == 1 && getfsize(f) > 1000000
      call rename(f, f . '.1')
    endif
    call writefile([strftime('%F %T ') . a:msg], f, 'a')
  catch
  endtry
endfunction

" -------------------------------------------------------------- channel ----
function! s:connected() abort
  return type(s:ch) == v:t_channel && ch_status(s:ch) ==# 'open'
endfunction

function! s:connect() abort
  if s:ws_off | return 0 | endif
  if s:connected() | return 1 | endif
  if localtime() - s:last_try < 2 | return 0 | endif
  let s:last_try = localtime()
  let sock = s:dir . '/bridge.sock'
  if getftype(sock) !=# 'socket'
    let s:state = 'offline'
    return 0
  endif
  try
    let s:ch = ch_open('unix:' . sock, {'mode': 'json',
          \ 'callback': function('s:on_msg'), 'close_cb': function('s:on_close')})
  catch
    call s:log('connect failed: ' . v:exception)
    let s:state = 'offline'
    return 0
  endtry
  if !s:connected()
    let s:state = 'offline'
    return 0
  endif
  call ch_sendexpr(s:ch, {'type': 'hello'})
  let s:state = 'idle'
  call s:log('connected to bridge')
  redrawstatus!
  return 1
endfunction

function! s:connect_retry(n) abort
  if a:n <= 0 || s:connect() | return | endif
  call timer_start(1000, {-> s:connect_retry(a:n - 1)})
endfunction

function! s:disconnect() abort
  if s:connected() | call ch_close(s:ch) | endif
  let s:ch = 0
endfunction

function! s:on_close(ch) abort
  let s:state = 'offline'
  call s:log('bridge closed connection')
  redrawstatus!
  let s:last_try = 0
  call timer_start(1500, {-> s:connect_retry(30)})  " bridge restarted: reconnect proactively
endfunction

function! s:send(msg) abort
  if !s:connect()
    return 0
  endif
  try
    call ch_sendexpr(s:ch, a:msg)
    return 1
  catch
    call s:log('send failed: ' . v:exception)
    let s:state = 'error'
    return 0
  endtry
endfunction

function! s:on_msg(ch, msg) abort
  try
    if type(a:msg) != v:t_dict | return | endif
    let t = get(a:msg, 'type', '')
    if t ==# 'result'
      call s:apply_result(a:msg)
    elseif t ==# 'status'
      let s:state = get(a:msg, 'state', 'idle')
      redrawstatus!
    elseif t ==# 'navigate'
      call s:navigate(a:msg)
    elseif t ==# 'agent_edit'
      call s:on_agent_edit(a:msg)
    endif
  catch
    call s:log('message handling error: ' . v:exception . ' @ ' . v:throwpoint)
  endtry
endfunction

" -------------------------------------------------------------- triggers ----
function! s:reviewable(...) abort
  " optional args: manual (echo reason), buf (default: current)
  let buf = a:0 > 1 ? a:2 : bufnr()
  let file = fnamemodify(bufname(buf), ':p')
  let why = ''
  if !empty(getbufvar(buf, '&buftype')) || empty(bufname(buf))
    let why = 'not a file buffer'
  elseif len(getbufline(buf, 1, '$')) > s:cfg.max_file_lines
    let why = 'file too large'
  else
    for re in s:ignore_re
      if file =~# re
        let why = 'file is ignored by config'
        break
      endif
    endfor
  endif
  if !empty(why) && a:0 && a:1
    echo 'AI: ' . why
  endif
  return empty(why)
endfunction

function! s:auto_ok() abort
  return !s:paused && !s:ws_off && s:cfg.auto_review
endfunction

function! s:on_change() abort
  let b:vimai_seen_tick = b:changedtick
  call s:schedule_ctx()
  if !s:auto_ok() || !s:cfg.review_on_idle || !s:reviewable()
    return
  endif
  call timer_stop(s:idle_timer)  " debounce: restart the idle timer on every change
  let s:idle_timer = timer_start(s:cfg.idle_review_delay_ms, {-> vimai#review('idle', 0)})
endfunction

function! s:on_move() abort
  call s:schedule_ctx()
endfunction

function! s:on_save() abort
  call timer_stop(s:idle_timer)
  let s:branch = {}
  if s:auto_ok() && s:cfg.review_on_save && s:reviewable()
    call vimai#review('save', 0)
  endif
endfunction

function! s:on_enter() abort
  call s:schedule_ctx()
  let f = expand('%:p')
  if has_key(s:findings, f) | call s:render(bufnr(), f) | endif
endfunction

" vimai#review(mode, manual [, buf [, reason]])
function! vimai#review(mode, manual, ...) abort
  let buf = a:0 ? a:1 : bufnr()
  if s:ws_off
    if a:manual | echo 'AI: workspace agents are off (:AIWorkspaceEnable)' | endif
    return
  endif
  if a:mode !=# 'diff' && !s:reviewable(a:manual, buf)
    return
  endif
  if a:mode ==# 'idle' && !a:manual && mode() =~# '^[vVs\x16]'
    return  " don't review mid-selection
  endif
  let cur = buf == bufnr() ? [line('.'), col('.')] : [get(getbufinfo(buf)[0], 'lnum', 1), 1]
  let msg = {'type': 'review', 'mode': a:mode, 'file': a:mode ==# 'diff' ? '' : fnamemodify(bufname(buf), ':p'),
        \ 'filetype': getbufvar(buf, '&filetype'), 'tick': getbufvar(buf, 'changedtick'), 'cursor': cur,
        \ 'manual': a:manual, 'reason': a:0 > 1 ? a:2 : ''}
  if a:mode !=# 'diff'
    let msg.lines = getbufline(buf, 1, '$')
  endif
  if s:send(msg)
    let s:state = 'reviewing'
    redrawstatus!
    if a:manual | echo 'AI: ' . a:mode . ' review requested' | endif
  elseif a:manual
    echo 'AI: review agent not reachable — try: vim-ai-restart review'
  endif
endfunction

" ------------------------------------------------------- results/display ----
function! s:buf_for(file) abort
  for b in getbufinfo({'bufloaded': 1})
    if fnamemodify(b.name, ':p') ==# a:file
      return b.bufnr
    endif
  endfor
  return -1
endfunction

" Find where an anchored line moved to; -1 if it's gone.
function! s:relocate(buf, line, text) abort
  let w = s:cfg.stale_search_window
  let lines = getbufline(a:buf, 1, '$')
  if a:line <= len(lines) && lines[a:line - 1] ==# a:text
    return a:line
  endif
  if a:text =~# '^\s*$' | return -1 | endif
  for d in range(1, w)
    for l in [a:line - d, a:line + d]
      if l >= 1 && l <= len(lines) && lines[l - 1] ==# a:text
        return l
      endif
    endfor
  endfor
  return -1
endfunction

function! s:apply_result(msg) abort
  let findings = get(a:msg, 'findings', [])
  if a:msg.mode ==# 'diff'
    let byfile = {}
    for f in findings
      let byfile[f.file] = add(get(byfile, f.file, []), f)
    endfor
    for [file, fs] in items(byfile)
      let s:findings[file] = fs
      let b = s:buf_for(file)
      if b != -1 | call s:render(b, file) | endif
    endfor
  else
    let file = a:msg.file
    let buf = s:buf_for(file)
    let kept = []
    let fresh = buf == -1 || getbufvar(buf, 'changedtick') == a:msg.tick
    for f in findings
      if f.file !=# file || fresh || !has_key(f, 'line_text')
        call add(kept, f)
        continue
      endif
      let nl = s:relocate(buf, f.line, f.line_text)
      if nl > 0
        let f.end_line += nl - f.line
        let f.line = nl
        call add(kept, f)
      endif
    endfor
    if !fresh && len(findings) && len(kept) * 2 < len(findings)
      call s:log('stale result discarded for ' . file)
      let s:state = 'idle'
      redrawstatus!
      return
    endif
    let s:findings[file] = filter(kept, 'v:val.file ==# file')
    if buf != -1 | call s:render(buf, file) | endif
  endif
  let s:state = 'idle'
  call s:update_qf()
  call s:schedule_ctx()
  redrawstatus!
endfunction

function! s:render(buf, file) abort
  call sign_unplace('vimai', {'buffer': a:buf})
  for name in keys(s:sev)
    call prop_remove({'type': 'VimAIVirt' . name, 'bufnr': a:buf, 'all': 1})
  endfor
  let n = len(getbufline(a:buf, 1, '$'))
  for f in get(s:findings, a:file, [])
    if f.line < 1 || f.line > n | continue | endif
    let sev = has_key(s:sev, f.severity) ? f.severity : 'INSIGHT'
    call sign_place(0, 'vimai', 'VimAI' . sev, a:buf, {'lnum': f.line, 'priority': 20})
    for l in range(f.line + 1, min([f.end_line, f.line + 30, n]))
      call sign_place(0, 'vimai', 'VimAI' . sev . 'Range', a:buf, {'lnum': l, 'priority': 19})
    endfor
    if get(s:cfg, 'show_virtual_text', 1) && sev !=# 'INSIGHT'
      let ind = matchend(getbufline(a:buf, f.line)[0], '^\s*')
      try
        call prop_add(f.line, 0, {'bufnr': a:buf, 'type': 'VimAIVirt' . sev,
              \ 'text': s:sev[sev][1] . ' ' . f.title, 'text_align': 'below', 'text_padding_left': ind})
      catch
      endtry
    endif
  endfor
endfunction

function! s:all_sorted() abort
  let all = []
  for file in sort(keys(s:findings))
    call extend(all, sort(copy(s:findings[file]), {a, b -> a.line - b.line}))
  endfor
  return all
endfunction

function! s:update_qf() abort
  let items = map(s:all_sorted(), {_, f -> {'filename': f.file, 'lnum': f.line,
        \ 'end_lnum': f.end_line, 'col': 1, 'type': s:sev[has_key(s:sev, f.severity) ? f.severity : 'INSIGHT'][0],
        \ 'text': printf('%-7s %s — %s', f.severity, f.title, f.message)}})
  if s:qfid && getqflist({'id': s:qfid}).id == s:qfid
    call setqflist([], 'r', {'id': s:qfid, 'items': items, 'title': 'AI review'})
  elseif !empty(items)
    " New list on the quickfix stack; earlier lists (e.g. :Grep) stay under :colder.
    call setqflist([], ' ', {'items': items, 'title': 'AI review'})
    let s:qfid = getqflist({'id': 0}).id
  endif
endfunction

function! vimai#open_findings() abort
  call s:update_qf()
  if !s:qfid
    echo 'AI: no findings'
    return
  endif
  let nr = getqflist({'id': s:qfid, 'nr': 0}).nr
  if nr > 0 | silent execute nr . 'chistory' | endif
  copen
endfunction

function! vimai#clear() abort
  for file in keys(s:findings)
    let b = s:buf_for(file)
    let s:findings[file] = []
    if b != -1 | call s:render(b, file) | endif
  endfor
  let s:findings = {}
  for b in getbufinfo({'bufloaded': 1})
    call s:clear_edit_marks(b.bufnr)
  endfor
  call s:update_qf()
  redrawstatus!
endfunction

" ]a / [a — explicit navigation is the only time the cursor moves.
function! vimai#jump(dir) abort
  let all = s:all_sorted()
  if empty(all)
    echo 'AI: no findings'
    return
  endif
  let cur = [expand('%:p'), line('.')]
  let target = {}
  let seq = a:dir > 0 ? all : reverse(copy(all))
  for f in seq
    let c = f.file ==# cur[0] ? f.line - cur[1] : (f.file ># cur[0] ? 1 : -1)
    if (a:dir > 0 && c > 0) || (a:dir < 0 && c < 0)
      let target = f
      break
    endif
  endfor
  if empty(target) | let target = seq[0] | endif  " wrap
  call s:goto(target.file, target.line, 1)
  call s:popup(target)
endfunction

function! s:popup(f) abort
  let lines = [s:sev[has_key(s:sev, a:f.severity) ? a:f.severity : 'INSIGHT'][1] . ' ' . a:f.severity . ' · ' . a:f.category . ' · ' . a:f.title]
  if !empty(a:f.message) | call add(lines, a:f.message) | endif
  if !empty(get(a:f, 'suggestion', '')) | call add(lines, '→ ' . a:f.suggestion) | endif
  call popup_atcursor(lines, {'moved': 'any', 'border': [], 'padding': [0, 1, 0, 1],
        \ 'maxwidth': min([90, &columns - 10]), 'highlight': 'Pmenu'})
endfunction

" ------------------------------------------------------------ navigation ----
function! s:goto(file, line, col) abort
  if a:file !=# expand('%:p')
    execute (&modified && !&hidden ? 'split ' : 'edit ') . fnameescape(a:file)
  endif
  call cursor(a:line, a:col)
  normal! zz
endfunction

" Trusted handler for bridge 'navigate' messages (from the chat agent).
function! s:navigate(msg) abort
  let file = fnamemodify(get(a:msg, 'file', ''), ':p')
  let line = str2nr(get(a:msg, 'line', 1))
  let col = max([1, str2nr(get(a:msg, 'col', 1))])
  if !filereadable(file) || isdirectory(file) || line < 1
    call s:log('navigate rejected: ' . file)
    return
  endif
  if mode() =~# '^[iRc]'
    let s:pending_nav = {'file': file, 'line': line, 'col': col}
    echo 'AI: jump to ' . fnamemodify(file, ':~:.') . ':' . line . ' pending (leave insert mode)'
    return
  endif
  call s:goto(file, line, col)
  redraw
  echo 'AI: jumped to ' . fnamemodify(file, ':~:.') . ':' . line
endfunction

function! s:flush_nav() abort
  if !empty(s:pending_nav)
    let n = s:pending_nav
    let s:pending_nav = {}
    call timer_start(0, {-> s:goto(n.file, n.line, n.col)})
  endif
endfunction

" ------------------------------------------------- live file updates ----
" Any open file changed on disk (agent, opencode, git, another editor) is
" reloaded automatically and its changed lines are marked. Unsaved edits are
" never overwritten.
function! s:poll() abort
  if mode() ==# 'n' && getcmdwintype() ==# ''
    silent! checktime
  endif
endfunction

function! s:on_fcs() abort
  let buf = str2nr(expand('<abuf>'))
  let name = fnamemodify(bufname(buf), ':~:.')
  if v:fcs_reason ==# 'deleted' || v:fcs_reason ==# 'mode' || v:fcs_reason ==# 'time'
    let v:fcs_choice = ''
    return
  endif
  if v:fcs_reason ==# 'conflict' || getbufvar(buf, '&modified')
    let v:fcs_choice = ''
    echohl WarningMsg
    echo 'AI: ' . name . ' changed on disk but you have unsaved edits — :e! to load it, :w to keep yours'
    echohl None
    return
  endif
  let s:fcs_old[buf] = getbufline(buf, 1, '$')
  let v:fcs_choice = 'reload'
endfunction

function! s:on_fcs_post() abort
  let buf = str2nr(expand('<abuf>'))
  if !has_key(s:fcs_old, buf) | return | endif
  let old = remove(s:fcs_old, buf)
  let new = getbufline(buf, 1, '$')
  let file = fnamemodify(bufname(buf), ':p')
  let [ranges, diff, added, removed] = s:diff(old, new, fnamemodify(file, ':.'))
  let msg = has_key(s:agent_files, file) ? get(remove(s:agent_files, file), 'agent', 'Agent') : ''  " '' = not an agent edit
  call s:mark_edits(buf, file, ranges, msg)
  if empty(msg) && !empty(ranges)
    " external change -> pane diff (the bridge drops it if an agent reports the same edit)
    if localtime() - get(s:recent_agent, file, 0) > 5
      call s:send({'type': 'show_diff', 'agent': 'external', 'file': file, 'diff': diff,
            \ 'added': added, 'removed': removed})
    endif
  endif
endfunction

" [ranges in new, unified diff text, added, removed] using the system diff.
function! s:diff(old, new, label) abort
  let [a, b] = [tempname(), tempname()]
  try
    call writefile(a:old, a)
    call writefile(a:new, b)
    let normal = systemlist('diff ' . shellescape(a) . ' ' . shellescape(b))
    let unified = system('diff -U2 --label a/' . shellescape(a:label) . ' --label b/' . shellescape(a:label)
          \ . ' ' . shellescape(a) . ' ' . shellescape(b))
  finally
    call delete(a)
    call delete(b)
  endtry
  let ranges = []
  let [added, removed] = [0, 0]
  for l in normal
    let m = matchlist(l, '^\v(\d+)%(,(\d+))?([acd])(\d+)%(,(\d+))?$')
    if !empty(m)
      let [s, e] = [str2nr(m[4]), str2nr(empty(m[5]) ? m[4] : m[5])]
      call add(ranges, m[3] ==# 'd' ? [max([1, s]), max([1, s])] : [s, e])
    elseif l =~# '^>' | let added += 1
    elseif l =~# '^<' | let removed += 1
    endif
  endfor
  return [ranges, unified, added, removed]
endfunction

function! s:mark_edits(buf, file, ranges, who) abort
  if !get(s:cfg, 'show_agent_edits', 1) | return | endif
  call s:clear_edit_marks(a:buf)
  let lines = getbufline(a:buf, 1, '$')
  for [a, b] in a:ranges
    for l in range(a, min([b, a + 300, len(lines)]))
      call sign_place(0, 'vimai_edit', 'VimAIEdit', a:buf, {'lnum': l, 'priority': 15})
      if !empty(lines[l - 1])
        call prop_add(l, 1, {'bufnr': a:buf, 'type': 'VimAIEditProp', 'length': strlen(lines[l - 1])})
      endif
    endfor
  endfor
  if empty(a:ranges) | return | endif
  let wid = bufwinid(a:buf)
  if get(s:cfg, 'agent_edit_follow', 1) && wid != -1 && mode() !~# '^[iRc]'
    call win_execute(wid, 'call cursor(' . a:ranges[0][0] . ', 1) | normal! zz')
  endif
  if s:auto_ok() && get(s:cfg, 'review_agent_edits', 1) && !getbufvar(a:buf, '&modified')
    " review everything uncommitted in this file (the agent's edit + yours), like :w
    call vimai#review('save', 0, a:buf, empty(a:who) ? 'external change' : a:who . ' edit')
  endif
  let spans = map(copy(a:ranges[:3]), {_, r -> r[0] == r[1] ? r[0] : r[0] . '-' . r[1]})
  echo '✎ ' . (empty(a:who) ? 'Updated on disk' : a:who . ' edited') . ': '
        \ . fnamemodify(a:file, ':~:.') . (len(a:ranges) == 1 && a:ranges[0][0] == a:ranges[0][1] ? ' line ' : ' lines ') . join(spans, ', ') . (len(a:ranges) > 4 ? ' …' : '')
endfunction

function! s:clear_edit_marks(buf) abort
  call sign_unplace('vimai_edit', {'buffer': a:buf})
  call prop_remove({'type': 'VimAIEditProp', 'bufnr': a:buf, 'all': 1})
endfunction

" Agent (chat) edit reported by the PostToolUse hook via the bridge.
function! s:on_agent_edit(msg) abort
  let file = fnamemodify(get(a:msg, 'file', ''), ':p')
  if !filereadable(file) | return | endif
  let s:recent_agent[file] = localtime()
  if mode() =~# '^[iRc]'
    call add(s:deferred_edits, a:msg)  " never reshuffle windows while typing
    let buf = s:buf_for(file)
    if buf != -1 && !getbufvar(buf, '&modified')
      let s:agent_files[file] = a:msg
      execute 'checktime' buf
    endif
    return
  endif
  let buf = s:buf_for(file)
  let how = get(s:cfg, 'agent_edit_open', 'full')
  if buf != -1
    let s:agent_files[file] = a:msg
    execute 'checktime' buf
    if bufwinid(buf) == -1 && how !=# 'none'
      call s:show_full(file, how)  " loaded but not visible: bring it on screen
    endif
    if has_key(s:agent_files, file)  " already reloaded by the poller: just re-label/mark
      call remove(s:agent_files, file)
      call s:mark_edits(buf, file, get(a:msg, 'ranges', []), get(a:msg, 'agent', 'Agent'))
    endif
    return
  endif
  if how ==# 'none' | return | endif
  call s:show_full(file, how)
  let buf = s:buf_for(file)
  if buf != -1
    call s:mark_edits(buf, file, get(a:msg, 'ranges', []), get(a:msg, 'agent', 'Agent'))
  endif
endfunction

" Show the whole edited file. 'full' = main editor window (previous file stays
" one Ctrl-^ away; unsaved buffers are hidden, never lost), 'split', 'preview'.
function! s:show_full(file, how) abort
  if a:how ==# 'preview'
    let cur = win_getid()
    execute 'silent pedit ' . fnameescape(a:file)
    call win_gotoid(cur)
    return
  endif
  " pick the main editing window: current if it is a normal file window
  if !empty(&buftype) || &previewwindow
    for w in getwininfo()
      if empty(getbufvar(w.bufnr, '&buftype')) && !getwinvar(w.winid, '&previewwindow')
        call win_gotoid(w.winid)
        break
      endif
    endfor
  endif
  execute (a:how ==# 'split' ? 'split ' : 'hide edit ') . fnameescape(a:file)
  setlocal noautoread
endfunction

function! s:flush_edits() abort
  let pending = s:deferred_edits
  let s:deferred_edits = []
  for m in pending
    call timer_start(0, {-> s:on_agent_edit(m)})
  endfor
endfunction

" ------------------------------------------------------------- context ----
function! s:schedule_ctx() abort
  if s:ws_off | return | endif
  call timer_stop(s:ctx_timer)
  let s:ctx_timer = timer_start(s:cfg.context_write_delay_ms, {-> s:write_ctx()})
endfunction

function! s:save_selection() abort
  let [s, e] = [line("'<"), line("'>")]
  if s > 0 && e >= s
    let s:last_sel = {'buf': bufnr(), 'start': s, 'end': e}
  endif
endfunction

function! s:selection() abort
  let m = mode()
  if m =~# '^[vV\x16]'
    let [s, e] = sort([line('v'), line('.')], 'n')
  elseif !empty(s:last_sel) && s:last_sel.buf == bufnr() && line('.') >= s:last_sel.start && line('.') <= s:last_sel.end
    let [s, e] = [s:last_sel.start, s:last_sel.end]
  else
    return v:null
  endif
  return {'start': s, 'end': e, 'text': join(getline(s, min([e, s + 200])), "\n")}
endfunction

" Heuristic enclosing function: nearest less-indented definition-looking line above.
function! s:enclosing_function() abort
  let lnum = line('.')
  let ind = indent(lnum)
  " %(...) = non-capturing groups (Vim allows at most 9 capturing groups)
  let def = '\v^\s*%(export\s+)?%(default\s+)?%(async\s+)?%(def|function|class|func|fn)>|'
        \ . '^\s*%(export\s+)?%(const|let|var)\s+\w+\s*\=\s*%(async\s+)?%(function|\(.*\)\s*\=\>|\w+\s*\=\>)|'
        \ . '^\s*%(%(public|private|protected|static|async)\s+)*[A-Za-z_$][a-zA-Z0-9_$]*\s*\(.*\)\s*%(:\s*[^{]+)?\{\s*$'
  let ctrl = '\v^\s*%(if|for|while|switch|catch|else|return|try|do|with|elif|except)>'
  let l = lnum
  while l >= max([1, lnum - 400])
    let t = getline(l)
    if t =~# def && t !~# ctrl && (indent(l) < ind || l == lnum)
      return {'line': l, 'text': trim(t)}
    endif
    let l -= 1
  endwhile
  return v:null
endfunction

function! s:git_branch() abort
  let d = expand('%:p:h')
  if empty(d) | let d = getcwd() | endif
  if !has_key(s:branch, d)
    let b = trim(system('git -C ' . shellescape(d) . ' rev-parse --abbrev-ref HEAD 2>/dev/null'))
    let s:branch[d] = v:shell_error ? '' : b
  endif
  return s:branch[d]
endfunction

function! s:write_ctx() abort
  if !empty(&buftype) | return | endif  " keep last real-file context (e.g. while in quickfix)
  try
    let lnum = line('.')
    let [a, b] = [max([1, lnum - 15]), min([line('$'), lnum + 15])]
    let near = map(range(a, b), {_, l -> printf('%s%4d| %s', l == lnum ? '>' : ' ', l, getline(l))})
    let file = expand('%:p')
    let func = s:enclosing_function()
    if get(s:cfg, 'review_function_exit', 0) && s:auto_ok()
      call s:function_exit_check(file, func)
    endif
    let ctx = {'project': $VIM_AI_ROOT, 'file': file, 'relative_file': expand('%:.'),
          \ 'filetype': &filetype, 'cursor': {'line': lnum, 'column': col('.')},
          \ 'current_line': getline('.'), 'nearby_code': join(near, "\n"),
          \ 'selection': s:selection(), 'function': func, 'modified': &modified ? v:true : v:false,
          \ 'git_branch': s:git_branch(),
          \ 'findings': map(copy(get(s:findings, file, [])), {_, f -> f.severity . ' line ' . f.line . ': ' . f.title})}
    let enc = json_encode(ctx)
    if enc ==# s:last_ctx | return | endif  " skip identical writes
    let s:last_ctx = enc
    let ctx.updated = localtime()
    let tmp = s:dir . '/context.json.tmp'
    call writefile([json_encode(ctx)], tmp)
    call rename(tmp, s:dir . '/context.json')
  catch
    call s:log('context write failed: ' . v:exception)
  endtry
endfunction

" Optional trigger B: left a function after changing it -> review now.
function! s:function_exit_check(file, func) abort
  let key = type(a:func) == v:t_dict ? a:file . ':' . a:func.line : ''
  if !empty(s:last_func) && s:last_func.key !=# key && s:last_func.file ==# a:file
        \ && b:changedtick != s:last_func.tick && mode() ==# 'n'
    call timer_stop(s:idle_timer)
    call vimai#review('idle', 0)
  endif
  let s:last_func = {'key': key, 'file': a:file, 'tick': b:changedtick}
endfunction

function! vimai#show_context() abort
  call s:write_ctx()
  echo 'AI chat context: ' . s:dir . '/context.json'
  echo system('vim-ai-context')
endfunction

" ----------------------------------------------------------- status/ctl ----
function! vimai#status() abort
  if s:ws_off | return '' | endif
  if s:paused | return '[AI: paused]' | endif
  if s:state ==# 'reviewing' | return '[AI: reviewing…]' | endif
  if s:state ==# 'offline' || s:state ==# 'error' | return '[AI: ' . s:state . ']' | endif
  let c = {'ERROR': 0, 'WARNING': 0, 'INSIGHT': 0}
  for f in get(s:findings, expand('%:p'), [])
    let c[f.severity] = get(c, f.severity, 0) + 1
  endfor
  let parts = []
  if c.ERROR | call add(parts, c.ERROR . ' error' . (c.ERROR > 1 ? 's' : '')) | endif
  if c.WARNING | call add(parts, c.WARNING . ' warning' . (c.WARNING > 1 ? 's' : '')) | endif
  if c.INSIGHT | call add(parts, c.INSIGHT . ' insight' . (c.INSIGHT > 1 ? 's' : '')) | endif
  return '[AI: ' . (empty(parts) ? 'idle' : join(parts, ', ')) . ']'
endfunction

function! vimai#status_verbose() abort
  let n = 0
  for v in values(s:findings) | let n += len(v) | endfor
  return printf('AI %s · bridge %s · auto-review %s · %d finding(s) · session %s',
        \ vimai#status(), s:connected() ? 'connected' : 'offline',
        \ s:paused ? 'paused' : 'on', n, $VIM_AI_SESSION)
endfunction

function! vimai#pause(v) abort
  let s:paused = a:v < 0 ? !s:paused : a:v
  if s:paused
    call timer_stop(s:idle_timer)
    call s:send({'type': 'cancel', 'file': expand('%:p')})
  endif
  echo 'AI auto-review ' . (s:paused ? 'paused (chat still available)' : 'resumed')
  redrawstatus!
endfunction

function! vimai#workspace(on) abort
  if empty($TMUX) || empty($VIM_AI_SESSION)
    echo 'AI: not inside a vdev tmux workspace'
    return
  endif
  if a:on
    let s:ws_off = 0
    call job_start(['vdev', '--panes', 'on', $VIM_AI_SESSION])
    let s:last_try = 0
    call timer_start(1500, {-> s:connect_retry(15)})
    echo 'AI workspace enabled'
  else
    let s:ws_off = 1
    call timer_stop(s:idle_timer)
    call vimai#clear()
    call s:disconnect()
    call job_start(['vdev', '--panes', 'off', $VIM_AI_SESSION])
    echo 'AI workspace disabled (agents stopped). :AIWorkspaceEnable to bring them back'
  endif
  redrawstatus!
endfunction

function! vimai#_test_enclosing() abort
  return s:enclosing_function()
endfunction
