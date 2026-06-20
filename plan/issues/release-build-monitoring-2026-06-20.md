# Release build monitoring — surface duration / cache-hit regressions instead of letting them run silently

- branch: linux-next
- status: ready
- owner_host: any (CI/workflow + ledger automation)
- source: operator report (Tlatoāni) 2026-06-20 — a ~10 min wasted-cache regression
  ran unnoticed across many releases
- pickup: Build/CI-capable worker. Add the timing capture + regression assertion
  below so future release slowdowns fail loud rather than accreting silently.

## Summary

The Nix-cache ref-scoping defect (see
[[release-nix-cache-ref-scoping-2026-06-20]]) wasted ~10 min/release for a long
time and nobody noticed, because **nothing watches release build performance**.
The release ledger records that a release happened, not how long its phases took
or whether the cache was hit. Correctness gates exist; a *performance* gate does
not. This packet adds one so the class of "silently slow release" bug surfaces.

## Why this matters

- A release that quietly doubles in wall-time is invisible until a human happens
  to watch the logs. That is exactly how this defect survived.
- Cache effectiveness is a leading indicator: a cache *miss* on an unchanged
  flake.lock is always a misconfiguration, and it is cheap to detect.

## Tasks

- id: capture-release-timings
  status: ready
  owned_files: [.github/workflows/release.yml]
  action: >
    Emit per-step durations for the expensive release steps (at minimum
    `nix build` and the cache save/`Post Nix Cache`) into the job summary
    (`$GITHUB_STEP_SUMMARY`) and as a small JSON artifact attached to the run.
    Capture cache hit/miss (cache-nix-action exposes a `hit`/`primary-key`
    output; or grep the Nix build log for "building '/nix/store…cross…gcc").
- id: assert-cache-hit
  status: ready
  depends_on: [capture-release-timings]
  owned_files: [.github/workflows/release.yml]
  action: >
    After the cache fix lands, add a soft gate: when flake.lock is unchanged vs
    the previous release tag, a full cross-GCC rebuild (or `nix build` step
    exceeding a threshold, e.g. >20 min) emits a `::warning::` (escalate to
    `::error::` once the fix is proven stable). This is the regression tripwire.
- id: ledger-release-timings
  status: ready
  owned_files:
    - skills/merge-to-main-and-release/SKILL.md
    - plan/issues/linux-next-work-queue-2026-05-25.md
  action: >
    Extend the merge-to-main-and-release skill's step 8 so the ledger entry
    records total run time and the `nix build` step duration (read back via
    `gh run view --json jobs`), giving a human-auditable performance trend line
    per release alongside the artifact URL.

## Notes

- Keep this lightweight: a job-summary table + one threshold warning is enough to
  catch a 2x regression. Do not build a metrics pipeline.
- The meta-orchestration release cycle should glance at the prior release's
  `nix build` duration before cutting the next one; if it jumped, link this
  packet rather than shipping blind.

## Events

- type: finding
  ts: "2026-06-20T19:55:00Z"
  agent_id: "linux-claude-opus48-20260620T1955Z"
  host: "linux_mutable (interactive Claude Code CLI)"
  note: >
    Filed alongside the ref-scoping fix packet. The fix removes the current waste;
    this packet ensures the next silent slowdown is caught by a performance gate
    instead of an operator noticing log spam months later.
