---
description: Performance analysis of the current function
argument-hint: [optional focus]
---
Analyze the current function for performance: repeated I/O or DB calls, N+1, sequential awaits that could be concurrent, unbounded concurrency, O(n^2) work, heavy sync work on async paths. Give concrete improvements with snippets.

Use the <vim-context> block attached to this message (file, cursor, enclosing function, selection). Extra focus from the user: $ARGUMENTS
