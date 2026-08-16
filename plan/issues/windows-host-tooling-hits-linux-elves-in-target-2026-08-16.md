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

## Update 2026-08-16 cycle 2: the same collision runs the other way, and it takes the MCP experts down

The daily cache sweep (cycle 1, 08:09Z, `swept target/ (59G)`) removed the
Linux ELF the WSL-side MCP servers exec; cycle 2's `cycle-preflight.sh`
rebuilt only the WINDOWS artifact and hardlinked it to the extensionless
`target/release/tillandsias-plan`. Result, observed 08:23Z: every
`forge-plan`/`project-info` MCP TOOL CALL on this host failed with

    forge-plan.sh: line 417: /mnt/c/.../target/release/tillandsias-plan: No such file or directory

(the wrapper's dev-env resolution prefers the checkout's
`target/release/tillandsias-plan`, which is now a PE32+ exe WSL cannot exec)
— while `check-mcp-expert-health.sh` reported `ok:experts-healthy`, because
the probe speaks only the `initialize` handshake and the wrapper starts fine;
the binary is exec'd per tool call. So the cycle ran on the documented
fallback (`./target/release/tillandsias-plan.exe` direct) with NO
`mcp_outage:` record possible — the probe cannot see this outage class.

Two additions to the smallest-next-action list:

1. The run-don't-stat probe (721-nyev) must ALSO be applied inside
   `images/default/config-overlay/mcp/forge-plan.sh`'s `resolve_plan_bin` —
   it currently trusts `-x` on the shared-target path, which is exactly the
   naive check this issue documents in host scripts.
2. The two lifecycles (Windows host tooling, WSL-side MCP servers) need
   disjoint artifact paths (e.g. a WSL-local CARGO_TARGET_DIR install for the
   expert binary, or TILLANDSIAS_PLAN_BIN pinned in the server registration)
   so a sweep+rebuild on one side cannot break the other. Until then, every
   post-sweep cycle on this host starts with broken experts.
