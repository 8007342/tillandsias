# Proposal — fleet-coordinator-warm-cache

- **Milestone:** `fleet-coordinator-warm-cache-milestone`, order `1824-58bm` (desired_release v0.5).
- **Children:** `1825-v37w` (Worker + Durable Object), `1826-gi8e` (client), `1827-3rj4` (mirror post-push), `1828-fz7r` (forge start), `1829-guit` (vault service tokens), `1830-hzsc` (deploy; the operator must approve it).
- **Related:** `1505-sm2j` (`--cloudflare-login`).
- **Approved by:** the operator, The Tlatoāni, 2026-10-23.

## Why

Hosts and forges coordinate only through git, so:

- A claim on one host stays invisible to the others until it reaches trunk. That has taken minutes to hours, and the same packet has been worked twice.
- Agents in different forges of the same project cannot leave each other a note.
- An idle agent asking "what's next" must fetch and fold the whole ledger.

A small cache reachable from every host fixes the speed problem. Git stays the source of truth.

## What changes

`coordinator.tillandsias.org` is a Cloudflare Worker with one SQLite-backed Durable Object, on the free tier. It sits behind Cloudflare Access and serves the operator's own fleet only. It does three things:

- **Message queues:** one per project namespace, best effort.
- **Plan overviews:** folded by the client, returned with freshness metadata.
- **Claim overlays:** short-lived, so a claimed row is hidden fleet-wide within seconds.

The fleet keeps it warm in three places:

- A client in `tillandsias-plan` (plus an MCP tool). It calls only when needed and falls back to the git ledger.
- The git mirror's post-push hook, after it pushes to GitHub.
- Forge start.

Each host's Access service token is created by `--cloudflare-login` and kept in the vault.

## Non-goals

- A public API, or any namespace listing.
- Folding the plan on the server, or running AI in the request path.
- Delivery guarantees or read receipts. The lane messaging in `msg_store.rs` (1506-nvqt) keeps its own receipt rules.
- A GitHub webhook.
