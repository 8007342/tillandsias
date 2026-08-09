# Simplified tray UX spec still mandates removed NanoClawV2 leaf

Date: 2026-08-05 (America/Los_Angeles)
Status: pending operator decision
Plan: `simplified-tray-ux-nanoclaw-spec-runtime-drift` (order 613-uy82)
Release: v0.5 audit

## Finding

The active `spec:simplified-tray-ux` still lists and mandates a NanoClawV2
project leaf. Repository history and the live image graph say NanoClawV2 was
migrated and then removed; no `images/nanoclawv2/` or `images/zeroclaw/`
runtime exists. The bound tray litmus instead pins the current Antigravity-based
seven-leaf implementation.

This leaves three claimed sources of truth disagreeing:

1. the active UX spec describes NanoClawV2;
2. the bound litmus describes the current Antigravity leaf set;
3. runtime/image code has no NanoClawV2 or ZeroClaw target.

The older dangling-component litmus is unbound and searches only for
`zeroclaw`, so it cannot catch a reintroduced `nanoclawv2` reference. A related
developer-build regression was removed under order 607, but the user-visible
spec is deliberately untouched.

## Why this packet is operator-gated

UX curation governance forbids an agent from deciding whether the intended
surface should restore NanoClawV2/ZeroClaw, retain Antigravity, or use another
curated leaf. Updating the spec to match runtime would itself select a UX
contract. This packet records the inconsistency and waits for explicit
operator approval of the canonical leaf set.

## Exit contract after approval

- Record the approved canonical project-leaf set in the plan ledger.
- Reconcile the active UX spec, runtime implementation, and bound litmus in one
  reviewed change; do not silently infer direction from whichever file is
  newest.
- Bind a no-dangling-component check that covers every retired spelling chosen
  by the decision.
- Preserve the v0.7 `zeroclaw-reintroduction-roadmap` as separate future work
  unless the operator explicitly changes that release decision.
