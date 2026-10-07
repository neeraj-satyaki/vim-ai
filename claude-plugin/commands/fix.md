---
description: Propose a fix for the code at the cursor (patch first, apply on confirm)
argument-hint: [optional focus]
---
Find the problem in the code at the cursor (selection/current function) and propose a minimal fix as a unified diff. Do NOT apply it until the user confirms; then apply exactly that patch.

Use the <vim-context> block attached to this message (file, cursor, enclosing function, selection). Extra focus from the user: $ARGUMENTS
