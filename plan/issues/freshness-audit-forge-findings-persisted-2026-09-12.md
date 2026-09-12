# Freshness audit — check-forge-findings-persisted — 2026-09-12

- **Classification**: optimization
- **Status**: completed
- **Auditor**: `forge-tillandsias-opencode-20260912t043200z`
- **Host**: `forge-tillandsias`
- **Component**: `scripts/check-forge-findings-persisted.sh`
- **Disposition**: **refreshed**

Standing freshness audit class (order 372): this cycle re-validated one
component. The component's prior stamp (`refreshed 2026-08-15
linux-immutable-20260814`) covered orders 741-3y48 / 743-rhr4 / 743-yej2 and the
negative-control contract. No material change to the file since; disposition
`refreshed`, matching the prior stamp, not `updated`.

Evidence (run from the checkout that will invoke it as the cycle-end GATE):

- `bash -n scripts/check-forge-findings-persisted.sh` — PASS.
- `bash scripts/check-forge-findings-persisted.sh fixture` — 12 scenarios all
  `ok`: negative control (clean cycle silent, `ok:no-findings` rc 0);
  uncommitted fails loud (rc 1); committed-but-unpushed fails loud (rc 1);
  pushed passes; `--since` reports `ok:findings-persisted`; the 743-rhr4
  uncovered-surface regression (plan/forge-improvements/proposals caught);
  the 743-yej2 local-branch-upstream poisoning refused with `unpushed` when a
  real remote counterpart exists; poisoned upstream with NO remote counterpart
  refuses `no-remote-tracking`; detached-HEAD committed finding refuses
  `no-remote-tracking`; off-Tillandsias project (no plan/) stays silent.

The verdict grammar is exercised end-to-end against real bare remotes (no
mock of git state), which is the gate's own contract: it must see what
`git status` cannot.

Coverage note: inventory reports 1712 components, 73 stamped (4.3%);
the defined-subset target is unchanged (delivered by `freshness-target:`
reading methodology.yaml). No denominator drift this cycle.

Interlock with this cycle's live-lane work (order 1080-4deb): the probe's
`ok:no-findings` for a committed-but-unpushed finding is exactly the state this
cycle must NOT end in — the claim + code + ledger commits below are pushed
before the attestation, and this gate is re-run at the very end.