# Component FRESHNESS lifecycle — never-ending staleness audit (operator directive 2026-07-15)

- **Type**: enhancement (methodology + CI/CD + skills; operator-directed)
- **Filed by**: linux-tlatoani-claude-20260715T2107Z
- **Status**: open — shaped; first rungs promoted to plan/index.yaml
- **Authority**: The Tlatoāni, verbatim directive 2026-07-15 (interactive session)

## Directive (distilled)

Our own components — code, scripts, documents, cheatsheets, litmus tests,
artifacts — age. The methodology must treat component lifecycle as a
first-class concern:

1. **FRESHNESS marking**: every module/component carries a freshness record —
   "when was this last *properly looked at* and confirmed still meaningful,
   useful, efficient, sound, and complete?"
2. **RE-FRESH flagging in CI/CD**: components whose freshness age exceeds a
   threshold get flagged; a flagged component dispatches an agent audit that
   ends in exactly one of: **refreshed** (re-validated, stamp updated),
   **updated** (fixed/tuned, stamp updated), or **obsoleted** (deleted or
   tombstoned — with the same-commit removal of anything that depended on it).
3. **Discard-over-repair bias**: agents must be able to *recognize* an
   obsolete component and discard it rather than reuse or repair it, when a
   fresh implementation would be better. Repair is not the default.
4. **Never-ending process**: this is a standing loop, not a one-shot audit —
   part of ./methodology and of the recurring skills
   (/meta-orchestration, /advance-work-from-plan), with transparent
   refresh/obsolete behaviors.

## Evidence this is needed (same day, same repo)

- `execute_test_command()` in scripts/run-litmus-test.sh was **dead code with
  zero call sites** that *looked like* the executor; a hardening pass patched
  it while the live path kept wedging the gate (fixed in 32ee1786 — one full
  wasted ci-full cycle). A freshness audit would have obsoleted it long ago.
- `litmus:environment-isolation`'s env allowlist was stale against a
  deliberate image change from the previous day (NODE_USE_SYSTEM_CA,
  6b299368) — first fresh-image ci-full flagged intended behavior as a
  regression (fixed in 8578e283).
- The OpenSpec gate already warns about 52-day-old changes
  (macos-tray-build-and-release, vm-recipe-provisioning) — a freshness signal
  that today has no owner and no closure path.
- tls-test-server.c carried a broken-by-construction SIGTERM handler
  (signal()/SA_RESTART) since authoring; nobody had re-audited it until it
  wedged three gate runs (fixed in 32ee1786).

## Shaped rungs (smallest-first; verifiable)

1. **Schema + methodology section** (this cycle): `component_freshness`
   section in methodology.yaml naming the invariant, the audit question, the
   three audit outcomes, and the discard-over-repair bias. FRESHNESS record
   format: a `freshness:` block (auditor, date, verdict) — machine-greppable.
   Verify: section parses; litmus asserts the section + record grammar exist.
2. **Inventory + first stamps**: a script that inventories auditable
   components (scripts/*, images/default/*, cheatsheets, litmus tests,
   methodology docs) and reports freshness coverage (stamped vs unstamped,
   age distribution). Exit code contract so CI can consume it.
   Verify: litmus pins the report grammar.
3. **CI RE-FRESH flagging**: local-ci (advisory phase first, per the
   migration ladder — flag→soak→default) lists the N oldest/most-stale
   components each run; meta-orchestration treats the top item as a
   claimable audit packet source.
4. **Skill integration**: /advance-work-from-plan and /meta-orchestration
   gain a standing "freshness audit" work class (audit one flagged component:
   re-validate meaningful/useful/efficient/sound/complete; then refresh,
   update, or obsolete — with the discard-over-repair bias stated).
5. **Obsolescence discipline**: tombstone pattern for removed components
   (what replaced it, why repair was declined) — the execute_test_command
   tombstone in run-litmus-test.sh is the exemplar.

Rungs 2-5 are promoted as plan/index.yaml packets under order 370+;
rung 1 lands with this filing.
