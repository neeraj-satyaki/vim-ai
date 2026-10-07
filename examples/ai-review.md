# Project Review Rules
<!-- Copy to <project>/.ai-review.md — included in every vim-ai review of that repo. -->

Architecture: Node.js, BullMQ, Redis, PostgreSQL, FastAPI, Next.js

Always check BullMQ workers for:
- duplicate execution, retries and idempotency
- Redis subscriber count and event listener cleanup
- concurrency, job timeout, graceful shutdown

Always check APIs for: auth, authorization, tenant isolation, validation, transactions.

Always check WebSocket code for: connection cleanup, reconnect behaviour, duplicated subscriptions, memory leaks.
