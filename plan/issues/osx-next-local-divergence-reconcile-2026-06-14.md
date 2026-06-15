# Unmerged osx-next local macOS UX-parity work — reconcile — 2026-06-14

A macOS-host session had 5 local `osx-next` commits + uncommitted WIP that were
NOT pushed and are NOT patch-equivalent to anything on `origin/osx-next`
(verified via `git cherry`). To FF-pull the 56 newer remote commits, the work
was parked (not dropped — CRDT: concurrent unique updates are not discarded):

- branch: `osx-next-local-pre-pull-2026-06-14` (5 commits, tip `942708d4`)
- stash:  `stash@{0}` ("pre-pull WIP osx-next 2026-06-14")

trace: methodology/convergence.yaml (cross_platform_ux_parity_policy — proposed in the stash)
       plan/issues/macos-windows-tray-ux-parity-audit-2026-06-13.md

## Work Packet: osx-next/reconcile-local-ux-parity-divergence

- id: `osx-next/reconcile-local-ux-parity-divergence`
- type: investigate
- title: Reconcile unmerged local macOS UX-parity commits with current osx-next
- owner_host: macos
- capability_tags: [git, macos, tray, ux, host-shell, windows]
- status: ready
- discovered_by: `/build-install-and-smoke-test-e2e` follow-up (CRDT drop check)
- evidence:
  - `git cherry -v origin/osx-next osx-next-local-pre-pull-2026-06-14` → all 5
    commits marked `+` (unique; not on osx-next).
  - `scripts/install-macos.sh:73-75` (HEAD) fetches generic `SHA256SUMS`; backup
    commit `942708d4` changes it to `SHA256SUMS-macos`.
  - `methodology/convergence.yaml` (HEAD) lacks `cross_platform_ux_parity_policy`
    that `stash@{0}` adds.
  - `crates/tillandsias-host-shell/src/menu_state.rs:331` (HEAD) still documents
    "exactly 9 top-level items"; backup/stash move to a condensed
    mutually-exclusive (logged-in vs github-login) menu.
  - `crates/tillandsias-macos-tray/src/action_host.rs:211,215` (HEAD) still uses
    `🟢 Ready` / `🟠 Draining`; backup/stash use "Verifying environment" /
    "Shutting down" parity strings.
- caveats:
  - `stash@{0}` is BROKEN WIP: its `notify_icon.rs` hunk deletes the
    `fn vm_phase_status_text(...)` signature, leaving a dangling body that will
    not compile. Do NOT `git stash apply` blindly — cherry-pick the intended
    content (the convergence policy + the Windows parity strings) by hand.
- next_action: >
    Decide per deliverable whether the local version or the current osx-next
    direction is canonical (the remote has since added vsock github-login poller
    work — d150a105 — that may intentionally supersede the local menu approach).
    Cherry-pick the still-wanted pieces (likely: SHA256SUMS-macos installer fix;
    cross_platform_ux_parity_policy) onto osx-next; explicitly discard the rest.
    Then drop `osx-next-local-pre-pull-2026-06-14` and `stash@{0}` once their
    content is either merged or consciously rejected.
- events:
  - type: discovered
    ts: "2026-06-15T03:00:00Z"
    agent_id: macos-claude-opus
    host: macos
