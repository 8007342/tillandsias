# Containerfile final-layer squashing — operator benchmark intake

Date: 2026-08-05 (America/Los_Angeles)
Owner: Linux mutable runtime/image lane
Plan: `container-image-final-layer-squashing` (order 607-vbbt)
Release: v0.5

## Operator evidence and provenance

The operator reported a laptop benchmark whose conclusion was that the many
overlay filesystem layers produced by Containerfile build steps impose runtime
overhead, and directed Tillandsias to squash the final filesystems. No raw
benchmark transcript, notebook, metrics event, or prior live plan packet was
found in the repository or folded ledger. This record preserves the finding
without inventing unavailable numbers.

The archived `layered-tools-overlay` change discusses a future SquashFS test
for bind-mounted tool directories over macOS virtiofs. That is a different
boundary: it does not measure or alter OCI image layers and is not a duplicate.
The Windows OCI flattener similarly produces a WSL import rootfs, not a Podman
runtime image.

## Live baseline

Read-only `podman image inspect` on Podman 5.8.4, rootless overlay storage:

| image | bytes | rootfs layers |
|---|---:|---:|
| forge | 3,133,641,111 | 65 |
| forge-base | 3,125,932,062 | 3 |
| chromium-framework | 1,906,383,444 | 13 |
| chromium-core | 1,038,676,152 | 7 |
| git | 579,647,559 | 18 |
| vault | 497,484,908 | 17 |
| inference | 158,911,746 | 12 |
| router | 115,931,307 | 15 |
| proxy | 23,113,721 | 8 |
| web | 8,267,269 | 4 |

`.Size` is uncompressed image content and does not establish store savings by
itself. Layer count, isolated-store bytes, archive bytes, load time, startup,
and rebuild behavior are separate measurements.

## Implementation decision

Use Podman `--squash`, not `--squash-all`, for every Tillandsias Containerfile
final image build. Podman's contract is precise:

- `--squash` combines the image's newly built layers into one new layer while
  retaining inherited layers.
- `--squash-all` also folds inherited base layers into that layer.

The latter has a concrete downside here: forge intentionally inherits and
shares the 3.126 GB forge-base image, while chromium-framework shares
chromium-core. Flattening inherited bases would duplicate that content across
final images and discard cross-image sharing. Squashing only the Containerfile
instruction layers addresses the reported many-step overlay depth while
preserving base reuse and Podman's intermediate build cache.

Squash-new is still a tradeoff, not literally cost-free: a late instruction
change can replace and transfer one larger final layer instead of a small tail
layer, and separate versions of the same final image cannot share their old
instruction layers as finely. That is why validation retains archive/pull size
and rebuild-time measurements alongside runtime layer depth. The large
inherited bases remain shareable, which bounds the downside for the current
image graph.

The policy must cover all three real builders:

1. compiled `tillandsias --init` (`podman_build_argv`);
2. compiled on-demand missing-image construction (`PodmanClient::build_image`);
3. `scripts/build-image.sh` and its routed developer wrappers.

The Nix `dockerTools.buildLayeredImage` reference tarballs do not execute
Containerfiles and are not a user-runtime build path. They retain their
explicit 100/20 layer policy until a separate reproducible Nix A/B proves that
changing it preserves Nix closure deduplication and archive behavior.

## Cache and identity contract

An unsquashed image must never be accepted as current after the policy flips.
The build policy therefore participates in the Rust content identity schema
and shell source hash and is emitted as
`io.tillandsias.image.layer-policy=squash-new`. Removing or changing the policy
must change the canonical content tag and force one rebuild; ordinary unchanged
rebuilds may continue using intermediate layer caches.

## Verification

- Unit/fixture argv checks cover all Rust and shell builders and forbid
  `--squash-all`.
- A final image has no more than `inherited base layers + 1` RootFS layers.
- Forge/chromium metadata and start/ready behavior remain identical.
- The clean-room smoke records layer counts after the runtime builds.
- A future isolated-store A/B records cold/no-op/late-change build time,
  compressed OCI archive bytes, store bytes after benchmark-owned cleanup,
  load duration, and start-to-ready. It must never reset or prune the shared
  operator store.

## Retry 4 interim image evidence

Local-build run `20260806T045626Z` constructed all ten images for generated
version `0.4.260806.1` before a later, unrelated post-build OpenCode launcher
failure stopped the E2E before destructive reset. This is therefore strong
builder evidence, but not the clean-store init/start completion gate.

| image | pre-change layers | inherited base | built layers | limit | inherited prefix | policy label |
|---|---:|---:|---:|---:|---|---|
| proxy | 8 | 1 | 2 | 2 | true | `squash-new` |
| git | 18 | 1 | 2 | 2 | true | `squash-new` |
| vault | 17 | 7 | 8 | 8 | true | `squash-new` |
| inference | 12 | 1 | 2 | 2 | true | `squash-new` |
| router | 15 | 5 | 6 | 6 | true | `squash-new` |
| chromium-core | 7 | 1 | 2 | 2 | true | `squash-new` |
| chromium-framework | 13 | 2 | 3 | 3 | true | `squash-new` |
| forge-base | 3 | 1 | 2 | 2 | true | `squash-new` |
| forge | 65 | 2 | 3 | 3 | true | `squash-new` |
| web | 4 | 1 | 2 | 2 | true | `squash-new` |

Every image also carried matching `io.tillandsias.image.name`, generated
version, and `source-digest` identity labels. The separate versioned
`forge-base` and `chromium-core` images remain in each child's inherited layer
prefix; neither was flattened into its consumer.

Podman's `.Size` became misleading for several squashed images: for example it
reported the new git image as 1,150,788,573 bytes even though `podman history`
shows an 8.09 MB Alpine base plus a 571 MB squashed delta. A read-only OCI
archive comparison against the retained pre-change tags did not reproduce a
transfer-size regression:

| image | layered OCI archive | squash-new OCI archive | delta |
|---|---:|---:|---:|
| proxy | 9,913,344 | 9,896,448 | -16,896 |
| git | 204,026,368 | 203,780,096 | -246,272 |
| router | 44,435,968 | 43,534,848 | -901,120 |

Those archives came from the shared build store and are useful paired
evidence, not an isolated performance benchmark. They show why layer depth,
`.Size`, transfer bytes, and physical store bytes must not be collapsed into
one metric. Order 608-ijbt owns the clean isolated A/B so this packet can close
on product correctness without inventing the missing laptop numbers.

## Retry 5 clean-store acceptance

Run `20260806T085959Z` tested commit
`c9ebd3f594da262594ea81ccb29e68fbd72d3d7c` through the complete local build and
install gate, then reset the shared Podman store only after that gate returned
zero. The immediate receipt showed zero containers, images, and volumes plus
zero teardown zombies/orphans. Cold `tillandsias --init --debug` rebuilt all ten
images and returned zero.

Direct image inspection then proved, for every image:

- the version alias and source-digest canonical alias resolve to the same image;
- `io.tillandsias.image.layer-policy=squash-new`, exact image name/version, and
  a valid source digest are present;
- the RootFS layer list begins with the exact direct-base layer list;
- the current Containerfile contributes exactly one new layer.

The clean counts were `proxy 1→2`, `git 1→2`, `vault 7→8`, `inference 1→2`,
`router 5→6`, `chromium-core 1→2`, `chromium-framework 2→3`, `forge-base 1→2`,
`forge 2→3`, and `web 1→2`. In particular, the framework and forge prefixes
match their separately tagged local bases; `--squash-all` was not used.

The hardened Chromium image emitted the expected DOM with the switch required
by its existing container sandbox policy, and the newly built forge launched,
cloned through the mirror, attached OpenCode, and exercised the plan expert.
The E2E found separate pre-existing terminal/probe defects (orders 612-nvf3 and
614-2gqx); neither changes the layer graph or invalidates the successful image
construction/start evidence.

The acceptance audit also removed a stale `nanoclawv2` developer selector from
`scripts/build-image.sh` and `scripts/hash-image-sources.sh`: its image directory
was already deleted, so it could only promise a target that failed
Containerfile discovery. The active init spec now names the actual ten-image
cold sequence, and the default-image shape litmus fails if a retired
NanoClaw/ZeroClaw selector returns. This cleanup is within order 607's image
builder/spec scope and changes no UX surface.

Order 607's product-correctness closure is now satisfied. The quantitative,
isolated storage/load/startup experiment remains intentionally separate as
ready order 608-ijbt.

Primary references:

- Podman build options: <https://docs.podman.io/en/stable/markdown/podman-build.1.html#squash>
- Nixpkgs `dockerTools` image functions: <https://nixos.org/manual/nixpkgs/stable/#sec-pkgs-dockerTools>

## 2026-08-06 measured cache correction (supersedes earlier claim)

Order 608-ijbt's isolated Podman 5.8.4 A/B disproved this report's statement
that `--squash` preserves a usable intermediate cache for ordinary unchanged
rebuilds. The historical implementation rationale above remains intact, but
that cache sentence is superseded.

With identical source contexts and separate stores, layered versus squash-new
median no-op times were git 5.95s versus 69.94s (11.75x), router 1.32s versus
62.83s (47.60x), chromium-framework 1.47s versus 46.71s (31.78x), and forge
10.04s versus 11.22s (1.12x). Layered logs used every step cache; squashed logs
re-executed the Containerfile. `podman build --help` reported `--layers`
defaulting true, so default intermediate-layer caching did not rescue this
invocation.

The final layer shape and inherited-base identity remain correct. The product
decision is now **revise**, not revert the goal blindly: order 617-mxqn must
prove a cache-preserving squashed materialization path or narrow squashing away
from incremental developer builds before the unconditional policy ships.
Quantitative evidence is in
`plan/issues/optimization/container-image-squash-isolated-ab-benchmark-2026-08-05.md`.
