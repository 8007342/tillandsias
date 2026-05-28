---
name: advance-work-from-plan
description: Pick the next bounded slice of READY work from the project plan and ship it. Agent-agnostic + host-aware. Replaces the per-cycle long-form work prompt; the orchestrator can edit this file between iterations to steer remote agent work.
license: MIT
metadata:
  author: tillandsias
  version: "1.0"
  invokedBy: /advance-work-from-plan
  cadence: ~30 min in active sessions; coordinate-multihost-work handles the 2h integration cron
---

# Advance Work From Plan

A single-iteration work cycle for **any agent** on **any host**. Pick one bounded
slice of READY linux/macOS/Windows-next work, ship it, exit. Designed for
unattended loops (cron, scheduler) and interactive use (`/advance-work-from-plan`
in TUI).

**Key property**: this file is committed to the repo. The orchestrator may edit
it between iterations to add a new priority focus, tighten guardrails, change
the defer window, or steer work toward a specific packet. Agents always load
the latest committed version at invocation time.

## 1 — Identify host + active branch

Detect which host you're on:

| Probe                              | Host    | Active branch |
|------------------------------------|---------|---------------|
| `uname -s` → `Linux`               | linux   | `linux-next`  |
| `uname -s` → `Darwin`              | macOS   | `osx-next`    |
| `uname -s` → `MINGW*`/`MSYS*`/`CYGWIN*` or `$OS == Windows_NT` | Windows | `windows-next` |

Verify with `git branch --show-current`. If the working branch is not the
host's active branch:

- Log the mismatch, do NOT switch.
- Skip to step 7 with a SKIPPED ledger entry.

The 2h integration cron (`coordinate-multihost-work`) handles cross-host
fast-forwards and merges; do not duplicate that work here.

## 2 — Refresh

```bash
git fetch origin --prune
git pull --ff-only origin <active-branch>
git status --short    # must be clean
```

If dirty with sibling/auto-artifact churn, `git stash` it (do NOT commit).
If truly blocked, write a SKIPPED ledger entry (step 7) and exit.

## 3 — Discover work

Read, in order:

1. `plan/index.yaml` — packet index + selection policy.
2. `plan/issues/<host>-next-*work-queue*.md` — your host's queue (e.g.
   `linux-next-work-queue-*`, `osx-next-work-queue-*`,
   `windows-next-work-queue-*`).
3. `plan/issues/forge-diagnostics-automation-2026-05-27.md`,
   `plan/issues/cross-host-blocker-roundup-*.md` — high-impact packets.
4. (linux) `plan/issues/linux-headless-spec-gaps-2026-05-27.md` —
   diagnostics + headless backlog.
5. Any other `plan/issues/*.md` referencing your host or "any host".

## 4 — Pick ONE bounded slice (30 min – 2 h)

Selection priority (top wins):

1. **Diagnostics-driven container-start verification** (USER PRIORITY,
   linux runtime-host today): work that strengthens the
   `--diagnostics` → annex → distill → litmus chain. See
   `scripts/forge-diagnostics-annex.sh`,
   `scripts/distill-forge-diagnostics.sh`,
   `openspec/litmus-tests/litmus-forge-diagnostics-e2e.yaml`,
   `methodology/forge-diagnostics.yaml` piggyback_protocol.
2. **Spec gap fills**: `openspec/specs/<spec>/spec.md` requirements
   without implementation coverage. Focus on
   `headless-mode`, `podman-idiomatic-patterns`,
   `runtime-diagnostics-stream`, `logging-accountability`,
   `observability-metrics`.
3. **Drift-protection litmus**: instant-phase tests pinning surfaces
   that recent work added (formatter literals, env-var contracts,
   public API names, unit-test names).
4. **Clippy / idiomatic-podman hardening**.

**Constraint**: ONE logical commit per cycle. If a slice estimates >2h,
split it and ship the first half.

**Delegate parallelizable research** (file inventory, stale-reference
audits, multi-file grep): use the host's available sub-agent tool
(Claude `Agent`, OpenCode/Codex equivalents). Keep ownership of specs,
verification, commits.

## 5 — Host scope (SOFT guidance + unblock-with-NOOP)

Each host has a primary write scope. You can READ everything; you should
normally only WRITE within your scope:

| Host    | Primary write scope                                                                                                                                                                                  |
|---------|------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| linux   | `crates/tillandsias-{headless,podman,control-wire,core,metrics,logging,vault-client}/`, `scripts/forge-diagnostics-*`, `scripts/distill-*`, `images/`, `openspec/litmus-tests/`, most `plan/issues/` |
| macOS   | `crates/tillandsias-macos-tray/`, `crates/tillandsias-vm-layer/src/{vz,transport_macos,materialize/macos}.rs`, `scripts/install-macos*`, `scripts/build-macos*`                                       |
| Windows | `crates/tillandsias-windows-tray/`, `crates/tillandsias-vm-layer/src/{wsl,materialize/windows}.rs`, `scripts/install-windows*`, `scripts/tray-diagnose.ps1`, host-shell pty windows files            |

Cross-host shared scope (any host may write, but COORDINATE via the
ledger first): `crates/tillandsias-control-wire/` (wire format —
WIRE_VERSION must not break), `crates/tillandsias-host-shell/`,
`methodology/`, `openspec/specs/`, top-level docs.

### Unblock-with-NOOP rule

If your work needs a function/type/file that lives in a sibling-owned
scope and doesn't exist yet, you MAY add a **minimal stub** there to
unblock yourself. Mark it explicitly:

```rust
// PLEASE REVIEW: <sibling-host> — minimal stub to unblock <your-work>.
// Owner: replace with the real implementation and add a brief
// `// DEPRECATED: superseded by <new-name>` comment here for one
// release cycle so callers can migrate.
pub fn placeholder() -> Result<(), String> {
    // TODO(<sibling-host>): implement
    Err("not yet implemented".to_string())
}
```

Cite the unblock in your commit body (`unblock-noop: <path>:<line>`) so
the sibling host can find it on their next cycle. Keep the stub tiny —
one function, one error, no business logic.

Sibling-owned cosmetic drift (e.g. rustfmt drift in their files
breaking your shared CI): flag in the ledger, do NOT reformat. Cite
`feedback_sibling_fmt_drift_flag_not_fix` if the project memory
records this preference.

## 6 — Execute + verify

```bash
cargo fmt --all
./build.sh --check
cargo test -p <crate-you-touched>      # targeted, fast
./build.sh --test                       # cross-cutting changes only
```

Hard rules:

- **Never bypass the idiomatic-podman layer.** The test
  `idiomatic_podman_launch_paths_do_not_bypass_shared_layer` enforces
  routing through `PodmanClient` — no direct `Command::new("podman")`
  in production launch paths.
- **Container security flags are non-negotiable**: `--cap-drop=ALL`,
  `--security-opt=no-new-privileges`, `--userns=keep-id`, `--rm`.
- **Pre-commit hooks and release signing** are not optional.

## 7 — Commit + push + ledger (unconditional)

```bash
git add <specific-files>      # NEVER `git add -A` (cross-host churn)
git commit -m "<slice-message>"   # cite trace + plan packet + any unblock-noop
git push origin <active-branch>
# on non-ff: git fetch && git rebase origin/<active-branch> && push, ≤3x
```

The ledger entry is the cross-host advertisement of your shipped work.
Write a one-line outcome to your host's work-queue ledger
(`plan/issues/<host>-next-work-queue-*.md`):

```
- 2026-MM-DDTHH:MMZ  <commit-sha>  <one-line summary>
```

### Defer rule

If the 2h integration cron fired in the last 10 min (check the latest
`### Cycle` timestamp in
`plan/issues/multi-host-integration-loop-2026-05-24.md`), write a
no-op ledger entry and exit. The cron's writes need to settle before
another work commit lands.

### Output line

A single line back to the invoker:

```
Work slice <UTC> — shipped: <one-line>. Tests: <pass|n/a>. Delegated: <agents|none>. Next: <one-line>.
```

## Hard guardrails

- NEVER `git push --force`.
- NEVER push directly to `main` — use PRs. Check
  `plan/issues/cross-host-blocker-roundup-*.md` for the active
  `<host>-next → main` PR number before opening a duplicate.
- NEVER push to a sibling host's branch (linux MUST NOT push to
  `osx-next` or `windows-next`).
- NEVER skip hooks or signing.
- `release.yml` / `recipe-publish.yml` workflows are
  `workflow_dispatch` only — never auto-trigger.
- NEVER resolve cross-host plan conflicts by deletion — tombstone or
  supersede only.
- When the worktree is dirty, only stage `plan/` files explicitly by
  path. Implementation code from a previous (uncommitted) iteration is
  NOT yours to touch.

## How orchestrators steer this skill

The canonical file lives at `skills/advance-work-from-plan/SKILL.md`.
Each agent runtime (`.claude/`, `.opencode/`, `.codex/`, `.gemini/`,
`.github/`) accesses it via a symlink under its `skills/` directory, so
there is exactly one source of truth.

To steer remote agent work between iterations, an orchestrator can:

- Edit the priority list in §4 to elevate a packet for the next cycle.
- Tighten or loosen the defer rule in §7.
- Add a new host row to §1 (e.g. when a freebsd-host comes online).
- Drop or extend the unblock-with-NOOP rule in §5.

Commit + push the edit. Every subsequent invocation of this skill
reads the new version from disk — no agent code change required.

## Change Log

- **2026-05-28** (linux-tlatoani-fedora): Initial creation. Extracted
  from the per-cycle work-loop prompt that had been pasted into every
  Linux work loop / integration cron invocation. Adds:
  - host-detection table in §1
  - work-discovery order in §3
  - soft scope guidance + unblock-with-NOOP escape hatch in §5
  - explicit defer rule in §7
  Symlinked into `.claude/skills/`, `.opencode/skills/`,
  `.codex/skills/`, `.gemini/skills/`, `.github/skills/`. Future work:
  the existing `openspec-*` skills are still per-runtime duplicates
  (they differ in content between runtimes today, so a unification
  pass requires reconciliation before symlinking).
