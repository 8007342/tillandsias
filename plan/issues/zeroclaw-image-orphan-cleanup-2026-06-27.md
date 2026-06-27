# Orphaned ZeroClaw Image Plumbing After Binary Removal

**Status:** `ready`
**Owner:** linux
**Date:** 2026-06-27
**Kind:** cleanup / tech-debt
**Trace:** `spec:init-command`, `spec:default-image`

## Context

Order 114 removed the `tillandsias-zeroclaw` binary/crate and its release
artifacts. But the zeroclaw **container image** plumbing is still present and is
now orphaned — the binary it integrated with no longer exists. It appeared in the
P0 build logs (`BUILD zeroclaw`) because it is still in the `--init` image list.

It is marked **optional** (`is_optional_image`), so it does not block launch, but
it is dead weight that references a removed component and confuses the build path.

## Orphaned references to remove

- `images/zeroclaw/` directory (Containerfile, entrypoint.sh, config-overlay,
  `config-overlay/mcp/zeroclaw-host.sh` which references the removed
  `tillandsias-zeroclaw` host socket)
- `crates/tillandsias-headless/src/main.rs`:
  - `"zeroclaw"` entry in the `run_init` images array (~line 3272)
  - `"zeroclaw"` in `is_optional_image` (~line 3236)
  - `image_specs` match arm `"zeroclaw" => "images/zeroclaw"` (~line 1132)
  - zeroclaw identity-chain branch (~line 1182) and build-arg arms (~1446/1467)
  - ordering test references (~lines 9341, 9496-9542) — update or remove
- Any `spec:zeroclaw-orchestration` references that are now dead

## Caution

This touches the identity chain and ordering tests, so it is a non-trivial,
test-heavy edit. It was deliberately deferred out of the P0 proxy hotfix
(order 116) to keep that fix tight and low-risk. Do this as its own packet under
the smoke lock (source-mutating, file-moving migration).

## Exit Criteria

- `images/zeroclaw/` removed
- No `"zeroclaw"` references remain in the init image list, identity chain, or
  build-arg logic
- Image-ordering and image_specs tests updated and green
- `./build.sh --check` and `./build.sh --test` pass
- `--init` no longer attempts to build a zeroclaw image

## Related

- `plan/issues/zeroclaw-unauthorized-release-violation-2026-06-27.md` — order 114 (binary removal)
- `plan/issues/init-proxy-poisons-build-2026-06-27.md` — order 116 (P0 hotfix that surfaced this)
