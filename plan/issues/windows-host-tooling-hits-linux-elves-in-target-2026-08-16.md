# Windows host tooling trips over Linux ELFs in the shared target/ tree

- classification: optimization
- filed: 2026-08-16 (windows, yolanda, meta-orchestration cycle)
- status: open
- related: order 721-nyev (plan-binary-probe: `-x` is a claim, running is evidence)

## Observation

`scripts/regenerate-cheatsheet-index.sh` fails on the Windows host with

    target/debug/tillandsias-policy: cannot execute binary file: Exec format error

because the checkout's `target/debug/` holds a **Linux** `tillandsias-policy`
(written by a WSL run with an in-tree CARGO_TARGET_DIR), and the script only
tests existence before exec'ing it. The same mixed-platform pollution shape
was already fixed for `tillandsias-plan` by `scripts/plan-binary-probe.sh`
(order 721-nyev: run the binary as the probe, never trust `-x`), but every
OTHER script that execs a `target/` binary re-derives the naive check.

Workaround used this cycle: run the script inside the `tillandsias-build`
WSL2 distro via `scripts/with-wsl2-builder.sh` (where the Linux ELF is the
right artifact). Cost: one failed run + one re-exec (~30s), every time a
Windows cycle regenerates the index.

## Smallest next action

Generalize `plan-binary-probe.sh`'s run-don't-stat pattern into a shared
`resolve_target_binary <name>` helper (probe `<name>.exe` and `<name>` by
EXECUTING each candidate) and adopt it in `regenerate-cheatsheet-index.sh`;
grep for other `target/(debug|release)/` exec sites and count how many
re-derive the naive existence check.
