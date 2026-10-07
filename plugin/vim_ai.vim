" vim-ai — Claude review/chat layer around Vim (Satyaki Solutions)
" Active only inside a `vdev` AI workspace ($VIM_AI_ENABLED=1). Otherwise every
" command is a harmless no-op and no timers, autocmds or files are created.
if exists('g:loaded_vim_ai') || &compatible
  finish
endif
let g:loaded_vim_ai = 1

let s:cmds = ['AIReview', 'AIReviewFile', 'AIReviewDiff', 'AIFindings', 'AIClear',
      \ 'AIReviewPause', 'AIReviewResume', 'AIReviewToggle', 'AIChatContext',
      \ 'AIWorkspaceEnable', 'AIWorkspaceDisable', 'AIStatus']

if $VIM_AI_ENABLED !=# '1' || empty($VIM_AI_SESSION_DIR) || !has('channel') || !has('timers') || !has('textprop')
  for s:c in s:cmds
    execute 'command! -nargs=* ' . s:c . " echo 'AI integration is disabled for this session.'"
  endfor
  function! VimAIStatus() abort
    return ''
  endfunction
  finish
endif

function! VimAIStatus() abort
  return vimai#status()
endfunction

command! -nargs=0 AIReview           call vimai#review('idle', 1)
command! -nargs=0 AIReviewFile       call vimai#review('file', 1)
command! -nargs=0 AIReviewDiff       call vimai#review('diff', 1)
command! -nargs=0 AIFindings         call vimai#open_findings()
command! -nargs=0 AIClear            call vimai#clear()
command! -nargs=0 AIReviewPause      call vimai#pause(1)
command! -nargs=0 AIReviewResume     call vimai#pause(0)
command! -nargs=0 AIReviewToggle     call vimai#pause(-1)
command! -nargs=0 AIChatContext      call vimai#show_context()
command! -nargs=0 AIWorkspaceDisable call vimai#workspace(0)
command! -nargs=0 AIWorkspaceEnable  call vimai#workspace(1)
command! -nargs=0 AIStatus           echo vimai#status_verbose()

call vimai#setup()
