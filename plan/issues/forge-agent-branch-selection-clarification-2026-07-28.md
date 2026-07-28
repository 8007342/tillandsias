# Methodology gap: which branch does a forge-hosted agent use on a non-Linux host?

- **Class**: research/ (methodology clarification; no defect)
- **Found**: 2026-07-28, operator question (The Tlatoani) while launching an
  OpenCode v0.4 forge on a macOS host for v0.5 validation work
- **Filed by**: linux-mutable-metaorch-20260728

## The question

`methodology/multi-host-development.yaml` and the meta-orchestration skill pin
canonical branches per HOST kind (`macos` → `osx-next`, `windows` →
`windows-next`, Linux integration → `linux-next`) and define `forge` as its
own host kind (`TILLANDSIAS_HOST_KIND=forge`) with forge-specific cycle rules
— but no document states which branch a forge-hosted agent works on when the
forge container (always Fedora Linux) runs on a macOS or Windows host. An
operator reasonably guessed "linux-next, it being a Fedora 44 container."

## The actual (implicit) behavior

The forge does not choose: its clone comes from the enclave git mirror, and
the mirror is seeded from the HOST checkout's currently checked-out branch at
lane launch. The container OS is irrelevant. Consequences today:

- host checkout on `osx-next` → forge works on and relay-pushes to `osx-next`;
- host checkout on `linux-next` → same for `linux-next` (historical forge
  cycles show both shapes in `plan/loop_status.md`);
- host checkout on `main` → fail-closed twice since v0.4.260728.1: the
  order-476 committable-branch guard refuses the cycle at bootstrap, and
  server-side branch protection (enabled 2026-07-28) rejects any push.

## Reduction (smallest closure)

Add one sentence to `methodology/multi-host-development.yaml` (and mirror it
in the meta-orchestration skill's Host Classification section): "A
forge-hosted agent inherits the branch its lane's mirror was seeded from —
the host checkout's checked-out branch at launch; the container OS never
selects the branch." Optionally pin with a litmus grep. Until then this file
is the citable answer.

## CLOSED 2026-07-28

The rule is now codified in `methodology/multi-host-development.yaml` →
`branch_namespaces.forge_branch_inheritance` (rung 1 of the branch scheme,
operator-directed; decision record:
`plan/issues/git-branching-methodology-research-2026-07-28.md`). This file
remains as the discovery record; the methodology text is the citable answer.
