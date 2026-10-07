---
description: Suggest/generate tests for the current code
argument-hint: [optional focus]
---
Write focused tests for the current function: error paths, boundaries, null/undefined, concurrency, timeouts, permission failures, malformed input. Match the project's existing test framework and style (look for existing tests first). Show the test code; only create files if the user asks.

Use the <vim-context> block attached to this message (file, cursor, enclosing function, selection). Extra focus from the user: $ARGUMENTS
