# spec-index durable tier is unreachable under rootless podman — 801-a2by silently degrades to `target/`, which daily maintenance deletes (2026-09-04)

- Date: 2026-09-04
- Class: defect (silent degradation of a durable-tier guarantee)
- Area: `scripts/spec-index-ensure.sh` rung-1 resolution / 801-a2by durable tier / `check-build-cache-sweep.sh` interaction
- Severity: high — an expensive, correctly-designed cache is published into the one directory a routine GC removes wholesale, and nothing reports it
- Discovered-by: lenovinha (Fedora Silverblue, rootless podman) while taking 917-6iwv
- Status: open
- Filed-from: `linux-next` @ `17ea51aaa`, working tree clean at time of measurement

## Summary

Order 801-a2by moved the spec RAG index into a "durable tier" so the ~12-minute
embedding cost is paid once and survives forge destruction and reboot. The
preferred carrier (rung 1) is a podman named volume, chosen explicitly over a
host bind-mount for enclave-correctness reasons.

On a rootless-podman host, rung 1 is **unreachable from the host-side producer**,
and the fallback is `<checkout>/target/tillandsias-spec-index` (rung 4) — the
directory `cargo clean` removes wholesale during Start-Of-Day maintenance.

So on this class of host the durable tier is not durable, and the degradation is
silent: every diagnostic reports success.

## Measured, on lenovinha

The volume exists and podman reports a mountpoint:

```
$ podman volume inspect -f '{{.Mountpoint}}' tillandsias-spec-index-tillandsias
/var/home/lenovinha/.local/share/containers/storage/volumes/tillandsias-spec-index-tillandsias/_data
```

That path is not accessible to the producer, which runs outside the user
namespace that owns it:

```
$ ls -ld /var/home/lenovinha/.local/share/containers/storage/volumes/tillandsias-spec-index-tillandsias/_data
ls: cannot access '...': Permission denied
```

`_tillandsias_spec_index_paths` guards rung 1 with `[ ! -d "$_tsi_root" ]`. Under rootless podman that test fails for
**permission**, not for absence, `_tsi_root` is cleared, and resolution falls
through to rung 4:

```
$ scripts/spec-index-ensure.sh --where
spec-index:project=tillandsias
spec-index:volume=tillandsias-spec-index-tillandsias
spec-index:root=/var/home/lenovinha/claudia/tillandsias/target/tillandsias-spec-index
spec-index:serving=/var/home/lenovinha/claudia/tillandsias/target/tillandsias-spec-index
spec-index:serving-exists=yes
spec-index:entries=0
```

Note `volume=` and `root=` disagree while `serving-exists=yes`. Nothing in this
report says the durable tier was not used.

## Why this is worse than a slow path

`scripts/metrics-log-path.sh` already documents this exact hazard for a *different*
subsystem, and its reasoning applies here verbatim:

> NOT `target/`, AND THIS IS LOAD-BEARING (macuahuitl, 2026-08-26). `target/` was
> the first choice and it is wrong: daily maintenance runs `cargo clean` ... and
> `cargo clean` removes the target directory WHOLESALE.

The metrics log was moved out of `target/` for this reason. The spec index — far
more expensive to rebuild than a metrics log — still lists `target/` as a rung,
and on rootless-podman hosts it is the rung that wins.

Current exposure on this host: `target/` is 17 GiB against the 40 GiB size
trigger (`MAX_GIB` / `TILLANDSIAS_BUILD_CACHE_MAX_GIB` in check-build-cache-sweep.sh), so
the sweep has not fired yet. The age trigger is the nearer one. This is a live
fuse, not a hypothetical.

Cost being risked, measured here this cycle: **23,154 chunks** requiring a full
cold embed (the 801-a2by header records 9,910 chunks / ~12 minutes on macuahuitl;
this corpus is 2.3x that). 888-miiy already records yoga blowing both time bounds
at 21,592 embeddings with nothing persisted between attempts — the same wound.

## What is NOT claimed

- I have not shown the sweep has ever actually eaten an index on any host. The
  size trigger has not fired here. The claim is that nothing prevents it.
- I have not established how the *forge* (a container, inside the namespace)
  resolves this. It very likely reaches rung 1 correctly — which is precisely
  what makes the split dangerous: the producer publishes to rung 4 while the
  consumer reads rung 1, so the two can disagree about where the index lives.
  That divergence is the 890-t9pu writer/reader-path defect recurring in a third
  subsystem, and it should be measured before it is asserted.
- Whether `podman volume inspect` alone is a sufficient rung-1 liveness test on
  every host is not established; it is merely a better one than `[ -d ]`.

## Candidate remedies, unranked

1. Test rung 1 with a mechanism that distinguishes "absent" from "not permitted"
   — a successful `podman volume inspect` plus a *write probe performed inside a
   container* — rather than a host-side `[ -d ]` that a namespace guarantees will
   fail.
2. Make the degradation loud: if `volume=` resolves but `root=` is not under it,
   `--where` should say so, and the ensure path should emit a
   `note:spec-index-durable-tier-unavailable:<reason>` line. A cache silently
   demoted to a GC target is the guard-nobody-honours shape.
3. Exclude `target/tillandsias-spec-index` from `cargo clean` exposure — either
   by moving rung 4 to `.cache/spec-index` (following metrics-log-path.sh's
   precedent exactly) or by teaching the sweep to preserve it.

Remedy 3 is the cheapest and closes the data-loss half on its own; 2 closes the
silence; 1 closes the root cause. They are independent.
