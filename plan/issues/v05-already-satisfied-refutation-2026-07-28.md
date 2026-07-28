# Adversarial verification of "already satisfied" v0.5 claims — 2026-07-28

- **Class**: research/ (verification record; converts vague `ready` packets into
  precisely-scoped remainders)
- **Method**: a bucket-triage fleet asserted 8 v0.5 packets were already
  satisfied at HEAD and 2 were obsolete. Rather than close on assertion, a
  dedicated refutation pass re-derived EVERY exit criterion against HEAD with
  citations, defaulting to refuted when uncertain.
- **Result**: **9 of 10 claims refuted or partial. Exactly one packet
  (328) was safe to close.** A wrongly-closed packet silently drops real work;
  this pass prevented nine such drops in one cycle.

## Verdicts

| Order | Packet | Verdict | Remaining work (exact) |
|---|---|---|---|
| 328 | forge-shared-checkout-destructive-clean | **CONFIRMED-CLOSEABLE** | none — fixture re-run PASS this cycle |
| 137 | vsock-exec-chain-authn-authz | REFUTED | secure wire is **default OFF** (`vsock_server.rs:77-82` NotPresent⇒Off; `vz.rs:484-487` provisions "off") so the default listener HelloAcks any plaintext peer and never emits `Unauthorized`; the named `litmus:vsock-unauthenticated-peer-rejected` does not exist; spec still sanctions bare CID_ANY. Needs default-on flip (or ratified opt-in re-scope) + litmus + spec |
| 150 | post-login-cloud-refresh | REFUTED (partial) | code path confirmed real (order-276 sentinel funnel, `main.rs:11618-11675`), but ALL FOUR exit criteria ARE live observations and none was ever recorded. One attended live pass |
| 399 | forge-lsp-by-default | PARTIAL | config + image side done and litmus-pinned; one live go-to-definition check in a fresh forge session remains |
| 279 | host-lifecycle-race-safeguards | REFUTED (partial) | all six named commits verified ancestors and matching their slices, but the **N=10 provoked quit/relaunch litmus never existed** (no file, no script). Litmus + live convergence evidence |
| 319 | mirror-credential-helper-broker | REFUTED (partial) | EC1/EC2 verified live-proven; **EC3 (GitHub App adopt/reject decision record) missing** — research only recommends; order 390 still ready |
| 130 | agent-services-egress-allowlist-impl | PARTIAL | allowlist + entrypoint verified, litmus steps executed green; one recorded `TCP_DENIED` proxy-log audit for the three providers remains |
| 132 | agent-login-flows-impl | REFUTED (partial) | flows + Vault paths verified, but **`refresh_provider_oauth` does not exist anywhere in the repo**; what shipped is in-forge rotation harvest (order-340 pattern). Needs an explicit re-scope note + the TCP_DENIED audit |
| 158 | vault-blocking-watch | obsolete claim CONFIRMED, **deletion REFUTED** | mechanism is genuinely unimplementable (Vault OSS KV v2 has no blocking `GET ?wait=` — that is Consul; ours is community 1.18), BUT the intent is unserved (2s tick + 60s heavy presence poll at `main.rs:11629-11637` violate its own SC-01/SC-14) and order 151 lists it in `depends_on`. **Rewrite + repoint 151, do not delete** |
| 382 | guest-staged-gitdir-root-owned | obsolete claim REFUTED | gating is real but the claim named the WRONG switch: the facade is gated behind `TILLANDSIAS_FORGE_HOST_MOUNT=1`, not `TILLANDSIAS_FORGE_SRC_ISOLATION` (that is the retired order-342 macOS lane). The opt-in path still ships and already has a fix + pin (`chown_tree_to_forge_uid`, `litmus:forge-gitdir-staging-chown`). **Downgrade to low-priority opt-in-lane scope, not obsolete** |

## Coordinator conclusions

1. **Ledger-event assertions are not evidence.** Several claims traced back to
   a packet's own optimistic event rather than to code. The refutation pass
   read code and ran fixtures; that difference produced nine corrections.
2. **The 137 finding is the most consequential**: an authn/authz packet whose
   protection is default-off is materially different from "satisfied". It also
   sharpens order 145 (the cutover packet) — the flip is what closes 137.
3. **"Obsolete" needs the intent test.** Both obsolete candidates survived as
   rewrite/downgrade because the MECHANISM was dead while the INTENT was live
   (158) or the code still ships behind an opt-in (382). Deleting either would
   have dropped real work and, for 158, dangled order 151's dependency.
4. Nothing here changes release scope: all ten stay v0.5, now with honest
   remainders instead of ambiguous `ready`.
