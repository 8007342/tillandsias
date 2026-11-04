# Proposal — fleet-durable-instructions

- **Builds on:** `fleet-coordinator-warm-cache` (orders 1824–1830: the Worker,
  the Durable Object queue, Access service tokens) and `fleet-messaging-poc`
  (1506-3xu7: per-lane Maildir mailboxes, infrastructure-only receipts, TTL,
  secret-shaped refusal). Nothing here replaces either; it adds one message
  kind to each, and two forge tools.
- **Design only.** No code lands with this change. The operator decides the
  open questions in `design.md` before any packet is filed.

## Why

The operator's direction (2026-11-03), verbatim:

- "just like an agent spawns a sub-agent, we'll want them to also be able to
  span sub-agents in a different harness, on a different model"
- "you send a message to yourself, then restart the forge, read your message
  on a new forge"
- spawn "a new harness with a different model, on the same or a sibling
  project, with a seed prompt for work, and/or instructions from the cloud's
  queue for that project"
- "Live durable instructions with some TTL"
- "facilities for forges to reload and resume on an updated binary"

Today none of that is possible:

- A forge is `--rm`. When it stops, the agent's context is gone, and nothing it
  wrote is read by the next forge unless it was committed and pushed.
- The coordinator queue is best effort, with no receipts and a 24 h maximum
  TTL. A message can be read twice or lost; nothing says which.
- The lane bus (1506) acknowledges a message only when a mailbox has accepted
  it, never when the work was done, and it lives on one host.
- An agent cannot start another agent. Only the operator's tray click or a host
  CLI launches a forge.

## What changes

- **ADDED** message kind `instruction`. It is a durable, per-project work item
  with a TTL, at-least-once delivery, a lease while one agent works on it, and a
  `settle` that removes it. It is carried by the coordinator (new ops `put`,
  `take`, `settle`, `release`) and, when the coordinator is unreachable, by the
  local lane bus. If that is unavailable too, it goes into the project's git
  mirror under a dedicated ref.
- **ADDED** the resume slot. This is a self-addressed instruction keyed by
  project and agent role, not by forge instance, so it survives a forge
  restart. Every forge start reads its resume slot before its seed prompt.
- **ADDED** forge tool `forge.reload`. It writes the resume slot, then asks the
  host to restart this forge on the current images and binary. The new forge
  reads the slot.
- **ADDED** forge tool `agent.spawn {harness, model, project, seed_prompt |
  queue_ref}`. It asks the host to launch one child forge. The host enforces
  limits that need no operator decision. Anything outside them needs the
  operator's out-of-band consent.
- **ADDED** trust rule: an instruction or message body is untrusted input to
  the agent that reads it. It can ask for work within the reader's existing
  permissions. It can never grant one. Operator consent stays an out-of-band
  act (tray click, OS-verified approval), never a message.

## Non-goals

- A public API, cross-tenant queues, or any namespace listing. The coordinator
  stays personal-fleet-only behind Access.
- Paid Cloudflare features. Free-tier Durable Objects only.
- New fast polling. Every read rides an existing event or the coordinator's
  existing heartbeat (at most 120 s, with busy backoff, design §6 of the
  warm-cache change).
- Agents creating new identities, accounts or credentials.
- Message-level signatures. Access already stamps the sender, and relays do not
  exist.
