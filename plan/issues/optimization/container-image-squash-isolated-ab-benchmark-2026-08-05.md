# Container image squash isolated A/B benchmark

Date: 2026-08-05 (America/Los_Angeles)
Status: ready
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
