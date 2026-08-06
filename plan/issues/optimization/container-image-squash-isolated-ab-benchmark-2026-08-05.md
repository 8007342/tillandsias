# Container image squash isolated A/B benchmark

Date: 2026-08-05 (America/Los_Angeles)
Status: completed
Plan: `container-image-squash-isolated-ab-benchmark` (order 608-ijbt)

## Why this remains a separate measurement

The operator's laptop benchmark conclusion — excessive OCI layer depth adds
runtime overhead — is preserved in the order 607-vbbt implementation report,
but the raw benchmark and numeric results were not found. The live migration
proves the requested layer collapse; it does not independently quantify cold
build, store, load, or start-to-ready changes.

The first paired images also exposed a measurement trap. After `--squash`,
Podman's image-inspect `.Size` can look much larger even when the corresponding
OCI archive is slightly smaller. Layer count, logical/virtual size, archive
bytes, physical store bytes, cache reuse, and runtime startup are different
observables and must be reported separately.

## Bounded experiment

Use a benchmark-owned temporary Podman storage root. Build identical source
trees once with the prior layered policy and once with `squash-new`, selecting
at least git (many medium layers), router (package churn), chromium-framework
(shared large base), and forge (shared multi-gigabyte base).

Record for each policy and image:

- cold build wall/CPU time;
- unchanged no-op and forced rebuild time;
- a late one-file change rebuild;
- RootFS layer count and inherited-prefix identity;
- compressed OCI archive bytes;
- physical benchmark-store bytes after only benchmark-owned cleanup;
- load duration into a second temporary store;
- container create-to-ready time over repeated launches.

Never reset, prune, or mutate the operator's shared container store. Preserve
machine, filesystem, Podman/storage-driver, power-state, and sample-count
metadata so a laptop result is reproducible instead of anecdotal.

## Exit contract

The report must separate measured results from inference, retain raw command
receipts outside the checkout, and recommend keep/revise/revert using both
runtime latency and storage/transfer evidence. A result that only compares
`.Size` or only counts layers is incomplete.

## Verdict

**REVISE the implementation; do not release unconditional `podman build
--squash` on every incremental build path in its measured form.** Keep the
runtime goal of a base plus one final layer, but order 617-mxqn must find and
prove a cache-preserving materialization path or scope squashing away from
ordinary developer rebuilds.

The layer collapse is real, and three of four median create-to-ready samples
were modestly faster. The clean loaded-store and compressed-transfer savings
were only about 0.04% and 0.10%, however, while three repeated unchanged builds
regressed by 11.75x to 47.60x. Across the whole controlled build matrix,
measured wall time increased 83.85%.

## Run controls and provenance

Run `20260806T100224Z` tested commit
`038ab5bc1819b66e2aebd3ef4315f99c7f88bbda` with Podman 5.8.4 on Linux
7.1.6, x86_64, rootless overlay over Btrfs (`compress=zstd:1`). The host had
20 CPUs in `powersave`, 67.0 GB RAM, 346.3 GB free at preflight, and loadavg
0.14/0.38/0.67. A 10,800-second external timeout bounded the primary run.

Every Podman path was pinned under the benchmark run root: graphroot, runroot,
tmpdir, volumes, networks, events, HOME, XDG paths, hooks and CDI. Layered and
squash-new had separate build stores; each policy was loaded into a second
fresh store. Deterministic tar hashes proved byte-identical pristine, layered
and squash-new source contexts for git, router, chromium and default. The only
build-policy difference was `--squash` plus its identifying benchmark label.

The policies ran sequentially, layered first. Cold-build differences can
therefore include host page/package-cache warming and are reported as measured,
not attributed causally. The three repeated no-op samples within each isolated
store are the stronger cache evidence.

## Measured build results

Seconds are GNU `time` wall values. No-op is the median of three unchanged
rebuilds.

| final image | layered cold | squash cold | layered no-op | squash no-op | no-op ratio | layered forced | squash forced | layered late | squash late |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| git | 79.23 | 88.92 | 5.95 | 69.94 | 11.75x | 75.25 | 70.44 | 9.15 | 70.52 |
| router | 68.64 | 65.44 | 1.32 | 62.83 | 47.60x | 65.53 | 62.79 | 4.10 | 62.88 |
| chromium-framework | 39.19 | 41.39 | 1.47 | 46.71 | 31.78x | 45.38 | 55.19 | 2.37 | 62.83 |
| forge | 27.71 | 10.80 | 10.04 | 11.22 | 1.12x | 29.01 | 12.59 | 23.03 | 12.35 |

The separately shared cold bases were chromium-core 40.80s layered versus
44.47s squashed, and forge-base 251.63s versus 246.03s. Summing every recorded
cold, no-op, forced and late build gives:

| policy | wall seconds | user CPU seconds | system CPU seconds |
|---|---:|---:|---:|
| layered | 817.72 | 125.77 | 96.24 |
| squash-new | 1,503.37 | 186.37 | 123.03 |

The logs explain the no-op delta: layered builds emit `Using cache` for each
Containerfile step, whereas squash-new re-executes the steps. Squash no-op and
forced times nearly converge for git, router and Chromium. Podman reports
`--layers` defaulting to true on this host, so the earlier assumption that
ordinary `--squash` rebuilds would retain the intermediate cache is empirically
false for this invocation on Podman/Buildah 5.8.4.

## Layer graph and logical image size

All four child images retained the exact direct-base RootFS prefix. `.Size` is
included but is not treated as physical storage.

| image | layered layers (new) | squash layers (new) | layered `.Size` | squash `.Size` |
|---|---:|---:|---:|---:|
| git | 18 (17) | 2 (1) | 579,587,748 | 579,452,843 |
| router | 15 (10) | 6 (1) | 115,926,869 | 113,944,684 |
| chromium-framework | 13 (6) | 3 (1) | 1,904,857,144 | 1,904,173,373 |
| forge | 66 (63) | 3 (1) | 3,131,594,859 | 3,128,989,970 |

## Transfer, load and physical storage

| image | layered OCI bytes | squash OCI bytes | compressed delta | layered load | squash load |
|---|---:|---:|---:|---:|---:|
| git | 204,029,952 | 203,915,776 | -0.0049% | 3.17s | 2.00s |
| router | 44,435,968 | 43,534,336 | -2.0716% | 1.70s | 2.54s |
| chromium-framework | 744,329,216 | 744,237,056 | +0.0097% | 36.05s | 30.69s |
| forge | 1,111,690,240 | 1,110,698,496 | -0.1098% | 75.48s | 51.84s |

Across the four archives, raw bytes fell 2,099,712 (-0.100%) and zstd level-3
bytes fell 2,068,007 (-0.099%). Load time improved for three images and
regressed for router; this single sequential run is not sufficient to assign
causality to those transport timings.

The first host-side `du` attempt could not traverse image-owned mode-0700
directories and silently emitted undercounts from inside command substitution.
Those raw rows are retained but invalid. Authoritative values below use
`podman unshare du` with empty stderr and Btrfs raw-byte corroboration. The
already-passed before-prune point cannot be reconstructed and is recorded as
missing rather than inferred.

| store state | layered allocated | squash allocated | delta | layered apparent | squash apparent | delta |
|---|---:|---:|---:|---:|---:|---:|
| build store, after-prune/current | 6,974,140,416 | 6,379,307,008 | -8.53% | 6,556,551,478 | 5,971,064,186 | -8.93% |
| clean loaded store, current | 11,777,699,840 | 11,771,518,976 | -0.0525% | 10,956,725,463 | 10,952,648,225 | -0.0372% |

The build-store reduction mostly reflects discarded intermediate build-cache
content. The clean loaded stores—the closer proxy for user-runtime footprint—
differ by only 6,180,864 allocated bytes.

## Create-to-ready samples

Each cell has two warmups followed by 15 measured samples from the clean loaded
store. Times stop at readiness and exclude teardown.

| image | layered median | squash median | median delta | layered p95 | squash p95 |
|---|---:|---:|---:|---:|---:|
| git daemon health | 535.39ms | 465.93ms | -12.97% | 604.72ms | 606.63ms |
| router Caddy + sidecar | 477.00ms | 498.57ms | +4.52% | 492.71ms | 547.89ms |
| Chromium expected DOM | 831.24ms | 811.14ms | -2.42% | 940.99ms | 839.77ms |
| forge filesystem-ready | 305.03ms | 281.82ms | -7.61% | 345.90ms | 323.48ms |

Git used the image's exact `nc -w 1 127.0.0.1 9418 </dev/null` readiness
command manually because isolated XDG deliberately has no user-systemd timer
manager. Chromium used the same benchmark-only internal `--no-sandbox` and
bounded `/tmp` HOME/XDG/profile redirection for both policies. Forge measures
filesystem-ready only, not a full agent attach.

## Harness findings and isolation proof

The primary run completed all builds, inspection, archives and clean-store
loads, then stopped rc127 when Podman tried to schedule the Git image
HEALTHCHECK through absent user systemd. Lifecycle attempt 1 preserved 34
successful Git/router samples, then reproduced Chromium rc133 on a read-only
root with its HOME/profile unwritable. Attempt 2 retained the outer read-only,
network-none, cap-drop-all, no-new-privileges and keep-id boundary, redirected
only writable Chromium state to bounded tmpfs, and completed all 136 lifecycle
observations. These are harness/product-boundary findings, not squash failures;
the Chromium proof is also recorded under 615-x3b8.

Stable projections before, abort, resume-before, resume-after and EXIT compare
image ID/repository/tag/digest, container ID/name/image (excluding human uptime
status), volume/network identity, and GraphRoot/RunRoot/driver. Every stable
field was unchanged. All four benchmark stores had zero containers after
sampling. The default Podman store was never reset, pruned, built into, loaded
into or otherwise mutated by the experiment.

Raw receipts, logs, normalized metrics and harness scripts are mirrored outside
the checkout at
`/home/tlatoani/.local/state/tillandsias/benchmarks/container-image-squash-ab/20260806T100224Z`
(281 files; manifest SHA-256
`030606e22b8d959250572910b201cd5e91f19e72a174d26b80a948a0855fa1d2`).
OCI archives and benchmark stores remain under the ignored run root until the
operator no longer needs them.

## Measured versus inferred conclusion

Measured: layer count collapses to direct base plus one; clean loaded storage
and transfer savings are about one tenth of one percent or less; startup
medians are mixed but mostly modestly better; unchanged rebuilds lose step
cache for three diverse images; the full matrix takes 83.85% longer.

Inference: the missing laptop benchmark may have exercised a storage driver,
machine pressure or workload where deep overlay traversal matters more than on
this desktop Btrfs host. These results do not refute that environment-specific
finding. They do refute the claim that unconditional build-time squashing has
no downside. Order 617-mxqn owns the bounded redesign and repeat A/B.
