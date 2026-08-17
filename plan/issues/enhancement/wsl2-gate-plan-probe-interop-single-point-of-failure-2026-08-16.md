# build.sh --check dies inside tillandsias-build when WSL interop dies: the plan-binary probe's only live candidate is the Windows .exe

- classification: enhancement
- filed: 2026-08-16 (windows/Yolanda, operator-attended session)
- status: open
- packet: wsl2-gate-plan-probe-survives-interop-loss (order 778-zydb)
- related: scripts/plan-binary-probe.sh (704-zcgi, 721-nyev, 770-ifeg),
  scripts/with-wsl2-builder.sh, scripts/check-fragment-status-loss.sh

## Observation (measured live, 2026-08-16 ~21:00-21:30Z)

`./build.sh --check` went red on this host four consecutive runs at
"Checking for fragment status transitions the fold discards..." with
`violation:fragment-status-loss:0` + "tillandsias-plan not built; cannot
resolve the fold" — while the same check passed standalone in Git Bash
every time, and a 1 Hz probe of `./target/release/tillandsias-plan.exe
capabilities` from the host stayed green through an entire failing gate
run.

Root cause chain, each link verified in isolation:

1. On Windows, build.sh transparently re-execs inside the
   `tillandsias-build` WSL2 distro (scripts/with-wsl2-builder.sh) — the
   whole gate runs in Linux, not Git Bash.
2. Inside the distro, WSL interop was DEAD: executing any Windows .exe
   returned 126, and `/proc/sys/fs/binfmt_misc/WSLInterop` printed
   nothing (registration gone). Interop had worked earlier the same
   afternoon (the ~21:10Z gate run was green). The likeliest killer is
   the operator's concurrent lane-launch stress test churning the runtime
   `tillandsias` distro — destructive smoke unregisters that distro, and
   the WSL2 utility VM's binfmt_misc table is SHARED across distros.
3. With interop dead, resolve_plan_binary has no live candidate:
   - `./target/release/tillandsias-plan.exe` — exists, but exec = 126;
   - `./target/release/tillandsias-plan` (Linux) — absent, because the
     wrapper deliberately points CARGO_TARGET_DIR at a distro-native path
     (9p target/ makes cargo crawl), so no Linux binary is ever linked
     in-tree;
   - `command -v tillandsias-plan` — /root/.local/bin is on PATH only for
     LOGIN shells; the wrapper re-execs via non-login `bash -c`.
   So the probe fails, the check refuses (correctly — fail closed), and
   the ONLY trunk-protection gate is red for as long as interop is down.

A diagnostic footnote that cost real time: probing this through inline
`wsl.exe -- bash -c "... \$?"` from Git Bash produced FAKE rc=0 lines
(the outer shell expanded the escaped `$?`), which mimicked healthy
interop. Only a script file pushed into the distro produced trustworthy
numbers (exe-direct-rc=126).

## Recovery used this session

`cargo build --release -p tillandsias-plan` inside the distro
(CARGO_TARGET_DIR=/root/.cache/tillandsias-wsl2-target/tillandsias,
42.5s with warm deps), then run the gate with the probe's documented
override forwarded through WSLENV:

```
TILLANDSIAS_PLAN_BIN=/root/.cache/tillandsias-wsl2-target/tillandsias/release/tillandsias-plan \
WSLENV=TILLANDSIAS_PLAN_BIN ./build.sh --check
```

## Fix candidates (packet 778-zydb)

- resolve_plan_binary adds `$CARGO_TARGET_DIR/(release|debug)/
  tillandsias-plan` to its candidate list — the sibling
  `resolve_target_binary` (770-ifeg) already honours CARGO_TARGET_DIR;
  the PLAN resolver predates it and never learned. This alone makes the
  gate self-healing here once the wrapper (or any prior phase) has built
  the crate distro-natively.
- with-wsl2-builder.sh ensures a distro-native tillandsias-plan exists
  (cheap no-op cargo build) and exports TILLANDSIAS_PLAN_BIN itself.
- Optionally: a loud preflight in the wrapper naming dead interop
  (`test -x` is exactly the lie the probe doctrine warns about; probe by
  execution and REPORT `interop-dead` instead of failing five phases
  later with "not built").
