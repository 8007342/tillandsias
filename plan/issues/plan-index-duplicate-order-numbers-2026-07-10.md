# plan/index.yaml has 7 duplicate order numbers — "order N" references are ambiguous

- **Date**: 2026-07-10
- **Filed by**: macos meta-orchestration cycle 2026-07-10T00:40Z
- **Classification**: enhancement
- **Status**: open (promoted to plan/index.yaml order 263)

## Finding

While resolving the expected order-260 collision in the 2026-07-10 osx-next
merge (macOS `wsl-headless-unit-lock-namespace` vs windows
`windows-tray-local-projects-push-gap`, renumbered mine to 262 per the merge
discipline), a uniqueness scan showed the same collision class has already
merged into the ledger seven times, unresolved:

| order | packet_ids |
|---|---|
| 144 | forge-harness-icap-proxy, github-login-e2e-gate |
| 160 | stable-state-codes-research, race-safeguards-research, microsoft-linux-guest-research |
| 161 | macos-tray-state-code-status-ux, host-lifecycle-race-safeguards, microsoft-linux-guest-migration |
| 196 | macos-litmus-runner-bash-version-gap, audit-plan-cross-branch-writes |
| 197 | macos-tray-clippy-warnings, audit-credential-guard-windows |
| 201 | macos-build-check-podman-wrapper, litmus-runner-command-backslash-escaping |
| 224 | litmus-command-portability-dsl-research, forge-gitconfig-quarantine-and-injection |

Repro: `grep -o 'order: [0-9]*' plan/index.yaml | sort | uniq -d`.

## Why this slows us down

Cycle notes, loop_status entries, commit messages, and cross-host flags all
reference work as "order N". With duplicates, "order 161" names three different
packets on three different hosts — exactly the ambiguity that caused the
order-259/260 confusion risk this cycle. Each future collision that merges
silently makes historical references less trustworthy. Detection today is
manual eyeballing during conflict resolution; nothing fails loud.

## Proposed reduction (verifiable constraint, not prose)

1. **Uniqueness check**: `tillandsias-policy validate-yaml` (or a dedicated
   `tillandsias-policy plan-orders` subcommand) fails non-zero when
   `plan/index.yaml` contains a duplicate `order:` value among non-`done`
   packets (historic `done` duplicates may be grandfathered via an explicit
   allowlist to avoid rewriting history references). Pin with
   `litmus:plan-index-order-uniqueness`.
2. **Historic cleanup**: renumber the *newer/less-referenced* packet of each
   live duplicate pair (most are `done`; only renumber where status is still
   `ready`/`blocked`/`in-progress` so open references stay unambiguous),
   recording a renumber event on each touched packet.
3. Ruby-free, per order 261's precedent (Windows hosts have no ruby).

## Ownership

`pickup_role: any` — pure-Rust policy subcommand + ledger edit; no host
substrate needed.
