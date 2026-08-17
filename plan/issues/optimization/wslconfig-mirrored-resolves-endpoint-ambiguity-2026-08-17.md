# `networkingMode=mirrored` resolves the loopback-endpoint ambiguity — measured, and 718-nkm2's option C is now empirically closed

- classification: optimization
- filed: 2026-08-17 (windows/ESMERALDINHA, cycle 4)
- status: **RECOMMENDATION WITHDRAWN 2026-08-17 on operator decision — REVERTED
  on this host.** The measurement below is correct; the fix it recommends is
  not. `networkingMode=mirrored` collapses the Windows/WSL2 network boundary,
  which the sibling windows host assessed as a **lower security boundary** than
  the current configuration. More fundamentally it treated a **self-inflicted
  symptom**: the ambiguity existed only because a redundant ollama had been
  installed on Windows during bring-up, and
  `scripts/dev-inference-ensure.sh` had already settled 718-nkm2 in favour of an
  in-build-distro endpoint on the servers' own loopback. Removing the extra
  install removes the ambiguity with **no boundary change at all**.
  See `mirrored-networking-reverted-redundant-ollama-removed-2026-08-17.md`.
  **The cgroup-v2 correction further down this file is unaffected and stands.**
- related: **718-nkm2** (wsl2-inference-substrate-decision — this closes its
  option C branch with evidence), **718-ja7g** (endpoint contract),
  `plan/issues/research/loopback-endpoint-is-ambiguous-across-wsl2-2026-08-17.md`
  (the defect this addresses), order 437 (forge-src-tmpfs-topology / memory
  ceilings)

## Result

Cycle 3 measured that `http://127.0.0.1:11434` designated **two different
Ollama servers** depending on which side of the WSL2 boundary read it, and that
both answered. Writing a `%USERPROFILE%\.wslconfig` with
`networkingMode=mirrored` removes that:

| | before (NAT, no `.wslconfig`) | after (mirrored) |
|---|---|---|
| Windows `127.0.0.1:11434` | 0.32.13 | 0.32.13 |
| WSL2 `127.0.0.1:11434` | **0.32.14** | **0.32.13** |
| model sets | 8 models vs 2 | **byte-identical, 8 = 8** |
| Windows -> WSL2 `:11435` bind | unreachable | n/a (one address space) |

The model-set line is the clinching one: both sides now enumerate
`gemma3:270m, nomic-embed-text, phi3.5:3.8b, qwen2.5:0.5b, qwen3:0.6b,
smollm2:135m, smollm2:360m, tinyllama:1.1b`. Verified stable across two
`wsl --shutdown` cycles.

**The VPN risk did not materialise.** Mirrored mode is documented to conflict
with some VPN clients and this host runs three Cloudflare WARP processes; after
the switch, both Windows and WSL2 reached `https://github.com` with 200, and
`cycle-preflight.sh` still returned
`ok:cycle-preflight:rebuilt:ok:dev-inference-ready:...`. Recorded because the
risk was real enough to be worth naming in advance, and a negative result on a
named risk is worth as much as a positive one.

Revert is one file: delete `%USERPROFILE%\.wslconfig` and `wsl --shutdown`.

## Correction — cgroup v2 was never missing

Several earlier notes in this loop (originating from an onboarding survey and
repeated by me in packet descriptions) asserted:

> no `.wslconfig`, so cgroup v2 is not enabled in the guest and any podman
> `--memory`/`--cpus` flag is a silent no-op here; enabling cgroup v2 must
> precede any memory-ceiling work.

**That is false on this host.** Measured directly, in BOTH distros, before any
`.wslconfig` existed:

```
stat -fc %T /sys/fs/cgroup   ->  cgroup2fs
cat /sys/fs/cgroup/cgroup.controllers
  ->  cpuset cpu io memory hugetlb pids rdma
```

The `memory` controller is present and unified cgroup v2 is already mounted, so
podman resource limits are enforceable **without** any `.wslconfig` and without
`kernelCommandLine` flags. The claimed ordering constraint on order 437's
memory-ceiling work does not exist.

Recording the correction rather than quietly dropping it: the claim was repeated
across several cycles and would otherwise keep being cited as a prerequisite
that must be satisfied first.

## Trap found while applying it: `autoMemoryReclaim` is silently ignored in `[wsl2]`

`autoMemoryReclaim` belongs under **`[experimental]`**, not `[wsl2]`. Placed in
`[wsl2]`, WSL 2.7.11.0 prints

```
wsl: Unknown key 'wsl2.autoMemoryReclaim'
```

to stderr **on the next distro launch** and then ignores the setting. The file
looks correct, `wsl --shutdown` succeeds, and the feature simply never engages.
It is easy to miss because the warning is not attached to writing the file — it
appears later, interleaved with whatever command happened to start the distro.

Anyone copying a `.wslconfig` from documentation or another host should check
for that line on first launch rather than assume acceptance.

## The config applied, and why each line

```ini
[wsl2]
networkingMode=mirrored     # removes the endpoint ambiguity above
memory=8GB                  # explicit; matches what the 50% default yielded
processors=4

[experimental]
autoMemoryReclaim=gradual   # WSL2 otherwise never returns freed memory
```

`memory=8GB` is deliberately a no-op today (the default already produced
`MemTotal 8016488 kB`; the explicit setting produced 8133232 kB). Its value is
that the split stops moving silently: this host's whole purpose is producing
comparable timings, and a RAM upgrade would otherwise change the guest/host
split and quietly invalidate every number recorded before it.

`swap` is deliberately left at the default. Forcing `swap=0` converts thrash
into OOM-kill, and `cargo build -j4` on 4 cores is precisely the workload that
would hit it — thrash is slow, OOM is a failed build.

## Not claimed

Windows free RAM read 4.42 GB before and 9.01 GB after, **but that comparison is
confounded**: the "after" reading follows a full `wsl --shutdown`, which frees
the guest's memory regardless of `autoMemoryReclaim`. It is recorded as an
observation, not as evidence that reclaim works. Demonstrating reclaim needs a
sustained-load-then-idle measurement, which is a separate experiment.
