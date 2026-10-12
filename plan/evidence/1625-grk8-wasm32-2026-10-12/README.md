# 1625-grk8 evidence: the forge builds wasm32 projects offline (lenovinha, 2026-10-12)

All images were built on an ISOLATED podman store: graphroot and runroot under
/var/tmp/grk8-substrate.*, guarded so that nothing ran unless `podman info` GraphRoot
was the scratch path. The operator's store and enclave were never touched. The store
was removed by literal path afterwards.

| Image | Built from |
|---|---|
| PRE-FIX `grk8-prefix-base` + `grk8-prefix-forge` | `git show origin/linux-next:images/default/Containerfile.base` plus the unchanged forge Containerfile |
| FIXED `grk8-fixed-base` + `grk8-fixed-forge` | This branch |

Both report `rustc 1.98.1 (48a229cea 2026-09-01) (Fedora 1.98.1-1.fc44)`. The fixed
image adds `rust-std-static-wasm32-unknown-unknown-1.98.1-1.fc44`, the same
version-release as `rust`. The build refuses a mismatch.

Fixtures, staged on the host and mounted read-only (`in-forge-check.sh` runs inside
each image with `--network=none`):
- `libcrate`: a dependency-free cdylib/rlib.
- `bindgen`: a minimal `wasm-bindgen = "=0.2.100"` crate with its 14 dependencies
  vendored, so cargo needs no registry.
- `bin/wasm-pack`: 0.15.0, the exact cargo-quickinstall artifact lib-common installs
  on first run.
- `bin/wasm-bindgen`: 0.2.100, the CLI that wasm-pack would otherwise download to
  match the lockfile.

wasm-pack ran with `--mode no-install --no-opt`: no wasm-bindgen or binaryen download.
Nothing was fetched inside the container.

Results, both images in ONE run (`prefix-vs-fixed-folded-layer.txt`):

| Check | PRE-FIX | FIXED |
|---|---|---|
| `cargo build --release --target wasm32-unknown-unknown` (offline) | `error[E0463]: can't find crate for 'std'` | `grk8_lib.wasm` built |
| `wasm-pack build --target web` (offline) | `wasm32-unknown-unknown target not found in sysroot: "/usr"` | `pkg/` = `grk8_bindgen_bg.wasm`, `.js`, `.d.ts`, `package.json` |

IMAGE SIZE DELTA (podman image inspect .Size):

| Image | Pre-fix | Fixed | Delta |
|---|---|---|---|
| forge-base | 3,123,237,614 | 3,242,617,078 | +119,379,464 bytes (113 MiB) |
| forge | 3,133,879,369 | 3,250,280,526 | +116,401,157 bytes (111 MiB) |

The package's installed size is 112,808,759 bytes (rpm `%{SIZE}`). The std's rlibs
take 108 MiB under `/usr/lib/rustlib/wasm32-unknown-unknown`.

Why the package is in the main microdnf layer: the first build put it in its own `RUN`
(`first-run-separate-layer*.txt`). That layer measured 179 MB, a 170 MiB delta,
because the 56 MB rpm database is rewritten and copied into the new layer. Folding it
into the existing install layer saves about 57 MiB in every forge image. The
functional result was identical in both shapes.

Not covered here:
- wasm-pack's first-run download of a project-matching wasm-bindgen CLI and of
  binaryen. Those go through the enclave proxy at run time, as before. This row is
  about the target std, which no proxy could supply.
- The end-to-end cold-start publish of a Wrangler + wasm project. That is 1625-9qyw.
