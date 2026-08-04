# v0.5 EXPERTS + inference orchestration plan — 2026-07-29

- **Class**: project/ (coordinator drain plan)
- **Operator directive** (The Tlatoani, 2026-07-29): v0.5 work is mostly forge,
  inference, and experts — it needs little Windows/macOS coordination, so the
  fat Linux builder drains the queue. "Let's start work on those experts."
- **Host assignment**: `linux_mutable` (macuahuitl) is the primary drainer.
  Windows/macOS keep only their genuinely host-gated packets (live smoke,
  tray parity, VZ/WSL probes).

## Why this family first

The EXPERTS chain is the v0.5 headline (`forge-local-experts-milestone`,
order 391) and it is almost entirely Linux-drainable: container work, Rust,
spec work, and local inference. It also compounds — every expert that lands
makes subsequent agent cycles cheaper, because agents QUERY instead of
grepping (`methodology.yaml` invariants
`plan_is_queried_via_mcp_server_avoiding_heuristic_parsing` and
`forge_discoverability_via_baked_in_tellme_and_launch_trained_local_inference`).

## Dependency shape (verified via the compiled ledger engine)

```
393 experts-construction-research ──┐   (no deps; informs everything)
392 inference-startup-cleanup ──────┴──> 394 plan-methodology-experts-rung1
                                              ├──> 395 experts-opencode-affordance
                                              ├──> 396 experts-refresh-on-commit
                                              ├──> 457 cheatsheet-expert-rung1 ──┐
                                              └──> 400 code-expert (also 399) ───┤
456 forge-plan-metadata-mcp-server ───────────────────────────────────────────────┴──> 458 agent-forge-context-hooks
479 heterogeneous-inference-specs ──> 480 accel-probe ──> 483 sidecar, 484 router
                                  └──> 482 llama-server-engine-slot ──> 484
398 plan-yaml-compiled-editor (no deps)      399 forge-lsp-by-default (verify-only)
```

## Wave plan

**Wave 1 (in flight, disjoint file scopes)**
| Packet | Why first | Scope |
|---|---|---|
| 393 experts-construction-research | Decides WHAT an expert is mechanically before anyone builds one; must answer "is a compiled query tool strictly better than a model here?" | `plan/issues/` deliverable only |
| 392 inference-startup-cleanup | Gates 394; kills the indeterminate "may still be starting up" startup-context string agents cannot branch on | `images/inference/`, `container_deps.rs`, inference regions of `main.rs`, litmus |
| 479 heterogeneous-inference-specs | Sole gate on five packets (480–484); pure spec work | `openspec/specs/**` |

**Wave 2 (after 392+393 land)**
- **394 plan-methodology-experts-rung1** — the first real expert. 393's slice
  proposal decides its child packets; 10h as filed, so it splits.
- **456 forge-plan-metadata-mcp-server** — substantially advanced already by
  the macOS forge session (`images/default/config-overlay/mcp/forge-plan.sh`,
  commit a61aade2, wrapping the compiled `tillandsias-plan` CLI). Verify
  against exit criteria, then close or name the remainder. Held out of wave 1
  only to keep `main.rs` single-owner while 392 is in flight.
- **399 forge-lsp-by-default** — verification-only per the 2026-07-28
  refutation pass (config + image already done and litmus-pinned; needs one
  live go-to-definition check in a fresh forge session).

**Wave 3** — 395, 396, 457 (all gated on 394), then 400 and 458.
**Wave 4** — the accel chain: 480, 482, then 483/484 (the two 20h packets;
they split before drain).

## Rules for this campaign

1. **One owner per file region per wave.** `main.rs` is the contention point;
   never two agents in it simultaneously.
2. **Every drain reports which exit criteria it CLOSED and which REMAIN** —
   no packet flips `done` on a summary alone (2026-07-28 refutation lesson:
   9 of 10 "already satisfied" claims were false).
3. **Ledger edits go through the compiled engine** (`tillandsias-plan
   append-event`, which validates before flush) or line-based insertion +
   `cargo test -p tillandsias-plan`. Never a YAML reserialize; never trust a
   Ruby-only parse (it tolerates duplicate keys the engine rejects — the
   order-263 class, hit live 2026-07-28).
4. **Debt ceiling applies**: this campaign must leave the debt vector
   non-increasing at the v0.5 boundary (`philosophy.yaml`
   `multi_version_convergence`). Every packet closed with a remainder gets
   that remainder filed, not dropped.
5. **Obsolete-mechanism/live-intent** governs every sweep verdict
   (`philosophy.yaml` `obsolete_mechanism_live_intent`).
