# Windows build I/O still hammers NTFS over 9p — move the build's source reads into the WSL filesystem (667-kfyn)

- Date: 2026-08-10
- Class: `optimization/` — operator field report + Microsoft's own guidance
- Host: windows "Yolanda"
- Related: `with-wsl2-builder.sh` (operator directive 2026-07-15), the
  2026-08-10 host freeze forensics (664-frz0 — heavy host I/O was ambient
  context for the platform hang)

## Operator report

> "I've seen popup warnings originated from Microsoft Windows directly …
> saying something along the lines of 'heavy I/O applications like cargo
> build run better in WSL', so we might have been trashing the Windows
> filesystem instead."

That popup is Windows' Dev Drive / dev-workload advisory, and it is correct
about the mechanism: cargo's many-small-file access pattern is the worst case
for NTFS + Defender real-time scanning, and doubly so when the access arrives
from WSL over the 9p bridge.

## What is ALREADY offloaded (do not redo)

`scripts/with-wsl2-builder.sh` already:

1. Re-execs every `./build.sh` / `local-ci` invocation inside the dedicated
   `tillandsias-build` WSL2 distro (ext4-native toolchain, rustup, dnf).
2. Keeps `CARGO_TARGET_DIR` **distro-native** at
   `/root/.cache/tillandsias-wsl2-target/<repo>` (default; opt-out
   `TILLANDSIAS_WSL2_TARGET_IN_TREE=1`). Target artifacts, incremental
   metadata, and dep builds never touch NTFS.
3. Keeps the cargo registry/git caches under `/root/.cargo` (ext4).

## What is NOT offloaded — the residual

The **checkout itself** stays on NTFS: the re-exec does
`wsl --cd <C:\ path>` and the tree lands at `/mnt/c/...` via automount. So
per build, over 9p → NTFS (+ Defender):

- every crate source read by rustc/cargo metadata (thousands of small files),
- `git status`/hook traversals (the post-freeze pushes this session hung for
  minutes on exactly this),
- build-script probes, `include!`/asset reads, litmus fixture reads.

9p read amplification is the single remaining reason a `--check` here takes
multiples of the Linux siblings' time.

## Proposed reduction (the packet)

Add an opt-in (then default-on once proven) **distro-native source mirror**
to `with-wsl2-builder.sh`:

1. Maintain `/root/.cache/tillandsias-wsl2-src/<repo>` as a git clone whose
   origin is the `/mnt/c` checkout.
2. Per invocation: `git fetch` from the /mnt/c tree (one bulk pack transfer —
   9p's GOOD case), check out the same HEAD, then apply the dirty diff
   (`git diff HEAD` piped in + untracked file copy) so the build sees the
   exact working tree, byte-identical.
3. Run the command with cwd in the mirror. Combined with the existing native
   CARGO_TARGET_DIR, NO per-file build I/O crosses 9p at all.
4. Verify: sync fidelity check (mirror `git status` hash equals source's),
   and a measured before/after `./build.sh --check` wall time recorded in
   the closing event.

Constraints:

- The Windows-native tray build (`tillandsias-windows-tray`, MSVC target)
  stays on the host by necessity — out of scope, it is not what the popup is
  about.
- Consumers that expect in-tree artifacts keep the existing
  `TILLANDSIAS_WSL2_TARGET_IN_TREE=1` escape hatch; the mirror needs an
  equivalent (`TILLANDSIAS_WSL2_SRC_IN_TREE=1`).
- Writes the build makes to the TREE (fmt, generated files) must be synced
  BACK or the mirror must refuse mutating commands — decide during
  implementation; `--check`/`--test`/clippy are read-only and cover the
  daily 9p pain already.

## Alternative considered

A Windows **Dev Drive** (ReFS, performance-mode Defender) would help native
tray builds too, but requires the operator to repartition and migrate the
checkout — file separately if the tray-side build ever becomes the
bottleneck. The WSL mirror is pure software, reversible, and matches
Microsoft's own "run it in WSL" advisory verbatim.
