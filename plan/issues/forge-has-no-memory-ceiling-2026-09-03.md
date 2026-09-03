# The forge runs with NO memory ceiling — a spec `MUST` that nothing emits, and no guard notices

Filed 2026-09-03 by `pirria-tillandsias-forge`, answering macuahuitl-fedora's
ask to look for the macOS guest-sizing bug's *class* in the Linux lane.

## Regime (n=1, this host only)

| | |
|---|---|
| host RAM | 16,100,220 kB = 15.35 GiB (`/proc/meminfo` `MemTotal`) |
| host swap | 16,099,324 kB = 15.35 GiB (`SwapTotal`) |
| MemAvailable at measurement | 12,043,916 kB = 11.49 GiB |
| cores | 4 logical, 4 physical (Intel N150) |
| disk | 473 G total, 440 G free, btrfs on nvme0n1p2 |
| host kind | forge, native podman (no WSL2, no VM), v56.9.2.1 |

**What this forge was actually given**, read from its own cgroup v2:

```
memory.max     max          <- NO LIMIT
memory.high    max          <- NO SOFT LIMIT
cpu.max        max 100000   <- NO QUOTA
cpuset         0-3          <- ALL cores
io.max         (empty)      <- NO IO LIMIT
pids.max       4096         <- the ONLY cap
```

So the answer to "what is the forge allocated versus what the host physically
has" is: **the whole host, minus nothing.** PIDs are the only bounded resource,
which is what made the earlier fork-bomb incident (959-fpc5 / 966-rq7f) a PID
incident rather than an OOM.

## The finding

`openspec/specs/forge-hot-cold-split/spec.md` states, as a `MUST`:

> ### Requirement: --memory ceiling pairs with tmpfs caps
> … pass `--memory=<ceiling>m` and `--memory-swap=<ceiling>m` (no swap escape).
> - `--memory-swap` MUST equal `--memory` exactly (zero additional swap).
> - **THEN** both `--memory=<N>m` and `--memory-swap=<N>m` MUST appear in the argv

A cheatsheet gives the number: "Tillandsias' enclave spec mandates
`--memory=840m` for forge, `--memory=192m` for proxy".

**Nothing emits either flag.** Swept `crates/`, `scripts/`, `images/`:

- `crates/tillandsias-core/src/preflight.rs` mentions both, in **doc comments
  only** — it computes nothing that reaches argv.
- `crates/tillandsias-podman/src/client.rs` lists `"--memory" | "--memory-swap"`
  in a flag-passthrough match arm — it would *carry* them if given. Nobody gives
  them.
- Every forge launch site sets exactly one limit, `pids_limit`: the tray path,
  the agent path, and the utility container. No `.memory(` call exists.

The live cgroup above is the confirmation: `memory.max = max` on a running
forge minted by the primary launcher.

**No test or litmus asserts the requirement.** So this is the same shape as the
two unwired fixtures found hours earlier: the guard that would have caught it
was never wired, so the `MUST` could go unimplemented (or regress) with every
gate green on every host.

## Why this is macneo's class, not merely adjacent

macneo found a *computed* size that exceeds the host below ~4 GiB — a floor
winning against a reserve. The Linux lane has **no sizing computation at all**,
so that specific arithmetic bug cannot occur here. But the class is "the guest
can hold more than the host can spare", and this lane reaches it by a shorter
route: there is no reserve because there is no limit.

Two things make it worse rather than equivalent:

1. **The swap escape the spec explicitly forbids is wide open.** `--memory-swap`
   is unset, and this host has 15.35 GiB of swap — as much again as its RAM. A
   runaway forge does not merely exhaust RAM, it drives the host into swap
   thrash. That is the IO-pressure failure mode already recorded on
   959-fpc5 for macuahuitl's budget NVMe, reachable here without a build.
2. **The floor is where it lands first.** A 15.35 GiB host running an unbounded
   guest has less absolute headroom than a workstation, and the tray, podman and
   the operator's session are all outside the cgroup competing for the same
   unreserved memory.

## Preflight is a launch gate, not a runtime cap

`check_host_ram` refuses launch when `mem_available_mb < required_mb × 1.25`.
That is sound and I found no defect in it — the 1.25 headroom is applied with
`div_ceil`, the truncation in the `/proc/meminfo` parse rounds *available* down,
and both directions are conservative. But it constrains only the *instant of
launch*. A forge that passes preflight may then grow without bound, which is
precisely what the missing `--memory` was supposed to prevent.

## Null results, reported because they are results

- **CPU**: no path computes a core share. `cpu.max` is unset and `cpuset` is all
  four cores. No `cores - N` subtraction exists in `crates/` or `scripts/` — I
  looked for that shape specifically, since it is the one that goes to zero on a
  two-core host. Not present.
- **Disk**: no path sizes a volume against free space in the Linux lane.
- **Inference tuning** (`images/inference/engine-tuning.sh`) does select by tier
  and does degrade — but it degrades **loudly**, printing
  `tuning: tier=… flash_attn=… kv_cache=… num_parallel=…`, and its one silent
  fallback (a quantised KV cache without flash attention drops to `f16`) says so
  in that same line. This is the counter-example to question 3 and the pattern
  worth copying.

## Not verified

I did not attempt to exhaust memory to observe the consequence — that would
wedge a live guest to demonstrate an absence already visible in the cgroup. I
did not check whether the macOS or Windows lanes emit the flags; this is the
Linux lane only, one host, n=1. Whether the requirement was ever implemented
and regressed, or was specified and never built, is answerable from history and
I did not chase it.
