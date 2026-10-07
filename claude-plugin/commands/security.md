---
description: Security review of the current function/file
argument-hint: [optional focus]
---
Inspect the current function (and file where relevant) for security issues: injection, authn/authz gaps, tenant isolation, secret leakage, unsafe logging, path traversal, unsafe deserialization. Report path:line with concrete fixes.

Use the <vim-context> block attached to this message (file, cursor, enclosing function, selection). Extra focus from the user: $ARGUMENTS
