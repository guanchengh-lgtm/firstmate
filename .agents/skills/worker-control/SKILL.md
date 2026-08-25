---
name: worker-control
description: >-
  Agent-only control procedure for worker communication.
  Load before steering a worker, resolving its decision, controlling its lifecycle, or retrying an unconfirmed remote send.
user-invocable: false
metadata:
  internal: true
---

# Worker control

Use `bin/fm-send.sh` for ordinary text.
It records the message durably and sends only a doorbell to the worker.
Multi-line text is valid locally and remotely.

After an unconfirmed remote delivery, retry only with the exact `FM_PENDING_REPLY_EXISTING_CORR=<id>` command printed by `fm-send`; it preserves the request body for remote deduplication.
When answering an open keyed decision or blocker, pass `--resolve-key` so the answer closes that record at delivery time.

Never use `fm-send`'s key or text paths for interrupt, exit, or other lifecycle control; routing-marked lifecycle text becomes chat the worker reasons about instead of executing.
Use `bin/fm-control.sh <task-id> interrupt|exit|relaunch`, which owns and verifies the runtime-specific action without discarding work; [`docs/agent-control.md`](../../../docs/agent-control.md) owns the operator contract.

A secondmate's routed reply returns through status or a referenced document, not by reading its chat.
`bin/fm-pending-reply-lib.sh` owns parent-side correlation, recovery, and escalation for marked secondmate requests.
`bin/fm-send.sh` and `bin/fm-control.sh` headers own exact commands and typed-plane exceptions.
