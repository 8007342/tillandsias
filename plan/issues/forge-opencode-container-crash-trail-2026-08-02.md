# Forge container crash on long-running OpenCode sessions — investigation trail

- **Date:** 2026-08-02
- **Class:** recurrence watch / infrastructure forensics (crash reproduces long-running OpenCode sessions)
- **Area:** forge container harness (OpenCode on Bun), x86_64 Linux guest
- **discovered_by:** operator (The Tlatoāni) — "some OpenCode sessions (like this
  one right now) crash the running container"
- **Session host:** forge container, branch `linux-next-debug`, agent OpenCode
  (this very session)

## Crash mechanism (leading hypothesis)

**opencode is PID 1 inside the forge container.** A segfault/panic in opencode
(or in the Bun runtime it embeds) terminates the entire container — there is no
supervisor to restart it. That is exactly the observed failure mode: "the
session crashes the running container."

- PID 1 cmdline: `/home/forge/.cache/tillandsias-project/npm/global/bin/opencode`
- PID 1 of THIS session: verified `ps -p 1` → opencode, RSS ~1.2 GB after ~10 min.

## The embedded runtime is the known-bad Bun v1.3.14

The opencode x86_64 binary embeds Bun v1.3.14 — the *same* runtime version that
segfaulted on arm64 in the prior incident:

- `strings opencode.exe | grep 'Bun v'` → `Bun v1.3.14`
- `strings opencode.exe | grep bun.report` → present (`https://bun.report`),
  plus `com.oven-sh.bun.Secret`, `/_bun/report_error`.
- Prior incident (2026-07-27, `forge-opencode-bun-segfault-2026-07-27.md`):
  Bun v1.3.14 Linux arm64, opencode 1.18.7, segfault at 0xD0, ~16 min in,
  623 subprocess spawns, RSS 0.49 GB of 4.08 GB — NOT OOM. Classed upstream
  crash, P2 recurrence watch.

This session's binary is opencode **1.18.10** x86_64 embedding **Bun v1.3.14** —
same runtime, same upstream class. The crash likely reproduces on spawn-heavy
long sessions (build loops, many `Command` spawns, fork churn).

## Environment forensics (captured 2026-08-02T17:2xZ)

| Signal | Value | Notes |
|---|---|---|
| arch | x86_64 | (prior incident was arm64) |
| opencode | 1.18.10 | `--version`; native ELF x86-64, embeds Bun v1.3.14 |
| opencode data | `~/.local/share/opencode/opencode.db` | 135 MB db + 14 MB WAL at 17:25, growing |
| opencode log | `~/.local/share/opencode/log/opencode.log` | 90 KB and growing; INFO level |
| cgroup memory.max | `max` (unlimited) | no cgroup cap on memory |
| cgroup memory.events | oom 0, oom_kill 0 | no OOM in this cgroup to date |
| cgroup pids.max | 512 | pids cgroup cap — watch for fork exhaustion |
| cpu.max | `max 100000` | 16 cores, no throttle |
| host RAM | 63.9 GB total / 52.9 GB available | host not memory-starved |
| root overlay | 897 G used / 52 G free / 952 G (95%) | **disk pressure near the top** |
| /tmp | tmpfs 256 M, 22 M used | small tmpfs — builds/logs can fill it |
| opencode threads | 53 | single session |
| total procs | 11 | quiet container otherwise |
| core_pattern | `\|/usr/lib/systemd/systemd-coredump …` | coredumps go to systemd-coredump (verify capture) |

Durable-host-mount observation: `/home/forge/.cache/tillandsias-project` is a
btrfs mount that persists across container re-creation — the right target for
crash forensics that must survive the container dying. `/tmp` (tmpfs) and
`/var/log/tillandsias/external` (absent) do NOT persist.

## What this is NOT (yet)

- Not a proven OOM: no oom_kill events; host has ample RAM.
- Not proven to be a Tillandsias defect: leading candidate is upstream
  Bun v1.3.14 segfault class (see 2026-07-27 incident), which is load/
  spawn-churn correlated.
- Not the terminal chain: prior crash banner rendered intact through the
  attach-client → vsock → guest PTY path.

## Actions / trail

1. **Recurrence watch**: reproduce a spawn-heavy long opencode session in
   automation (see `scripts/forge-longrun-crash-repro.sh`) and capture:
   PID 1 identity, opencode + Bun version strings, RSS/CPU trends, cgroup
   events, disk/`/tmp` fill, db/log growth, and — if the container dies —
   the last log tail plus any coredump. Log heartbeat + crash snapshots to
   the DURABLE host mount `$HOME/.cache/tillandsias-project/forge-crash-trail/`
   so they survive container re-creation.
2. **Upstream report** (if reproduced): file the `bun.report` trace against
   oven-sh/bun (x86_64 now, spawn-heavy workload; arm64 already on record).
3. **Mitigation candidates** (after reproduction confirms):
   - pin the forge image opencode/bun to a known-good pair (opencode pre-1.18.7
     or bun pre-1.3.14) in the forge Containerfile npm global install;
   - or wrap opencode in a supervisor inside the container so a Bun segfault
     restarts the agent instead of killing the container;
   - or add a small watchdog that commits+pushes session state so nothing is
     lost on a crash (push-early discipline, per the prior incident note).
4. **Trail location**: this file plus `scripts/forge-longrun-crash-repro.sh`
   and any `forge-crash-trail/` snapshots live on branch `linux-next-debug`
   for a later clean merge into `linux-next`.

## Related prior art

- `plan/issues/forge-opencode-bun-segfault-2026-07-27.md` — arm64 Bun v1.3.14
  segfault, same class, upstream; push-early lesson.
- `scripts/forge-liveness-probe.sh` — host-side liveness probe (order 265).
- `plan/issues/forge-agent-liveness-signals-research.md` — container
  crash detection vs in-process hang distinction.
