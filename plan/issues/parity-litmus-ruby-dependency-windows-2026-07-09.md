# Finding: litmus:tray-parity-matrix-complete cannot run on Windows hosts (ruby dependency) — 2026-07-09

- class: enhancement (litmus infrastructure / host portability)
- status: open — promoted to plan/index.yaml order 261
- trace: openspec/litmus-tests/litmus-tray-parity-matrix-complete.yaml,
  plan/index.yaml orders 243, 258, 224/225 (litmus command DSL),
  plan/issues/windows-yaml-validation cheat: `tillandsias-policy validate-yaml`
- filed_by: windows-bullo-fable5-20260709T2310Z (order 258 cycle)

## What

`litmus:tray-parity-matrix-complete` — the per-host parity gate that order 243
deliberately made RED until each host verifies its column — is implemented as
a single-line `ruby -ryaml` one-liner, with precondition "ruby is available in
PATH". This Windows host (and Windows hosts generally, per the standing
no-ruby note that also forced `tillandsias-policy validate-yaml` for YAML
checks) has no ruby. Consequence:

- Order 258's exit criterion 4 ("litmus:tray-parity-matrix-complete passes on
  the Windows host") is UNSATISFIABLE as written on this host — the check can
  never execute, let alone pass, even after the attended smoke flips all
  cells to done.
- The Windows `--ci-full` lane silently lacks the parity gate the whole
  order-243 design assumes is enforcing per-host honesty.

## Why it matters

A gate that cannot execute on the host it is supposed to gate is an
advisory-only guard (methodology: "a guard only an attentive agent honors is
a suggestion, not a constraint"). Windows is the only column whose gate
depends on an interpreter the platform convention says is absent.

## Proposed reduction (order 261)

Add a `parity-matrix` subcommand (or extend `validate-yaml`) to
`tillandsias-policy` implementing the same semantics (host column done on
required rows, valid status words, no `regressed` anywhere), and point the
litmus's command at it with the ruby one-liner retained as fallback where
cargo is absent. The policy crate is already the sanctioned no-ruby validator
on Windows, and a Rust implementation is testable + identical across hosts.
Overlaps orders 224/225 (litmus command DSL) but is a one-command slice that
unblocks order 258's exit criterion now.
