# build-guest-binaries.sh stages stale binaries when CARGO_TARGET_DIR is redirected (wsl2 wrapper)

- Date: 2026-07-16
- Class: optimization/bug (build tooling; silent-staleness with a masked failure)
- discovered_by: windows-bullo-fable5-20260716T0731Z (order-350/goal cycle)
- pickup_role: any (script is POSIX shell; repro needs the wsl2 wrapper or any
  CARGO_TARGET_DIR override)

## What happened

`scripts/with-wsl2-builder.sh scripts/build-guest-binaries.sh` compiled the
current tree fine (cargo fallback path), but the staging step copies from the
hardcoded `$ROOT/target/<triple>/release/tillandsias`
(build-guest-binaries.sh `build_with_cargo`), while the wsl2 builder redirects
`CARGO_TARGET_DIR` to `/root/.cache/tillandsias-wsl2-target/`. Result: the
fresh binary landed in the redirected target dir and the script staged
YESTERDAY's binary from the stale repo-local `target/`, then its own
`--verify` correctly failed the version check. Recovery this cycle: pulled the
artifact straight out of the wrapper distro
(`wsl -d tillandsias-build -- cat …/x86_64-unknown-linux-musl/release/tillandsias`).

Compounding near-miss (recurrence of the 2026-07-15 pipefail note): both
failures were initially masked by `… | tail -N` swallowing the script's
non-zero exit in the invoking harness.

## Also observed

- On a plain Windows Git Bash invocation (no wrapper), the Nix path is absent
  and the cargo fallback dies on missing musl targets (expected), but only
  after a long compile attempt; a preflight `rustup target list --installed`
  check would fail fast.
- `--verify`'s executability check reports NTFS-staged binaries as
  non-executable when stat'd from some mount views; harmless here but noisy.

## Smallest fix

In `build_with_cargo`, resolve the artifact dir from cargo itself instead of
`$ROOT/target`:

```bash
target_root="${CARGO_TARGET_DIR:-$ROOT/target}"
install -m 0755 "$target_root/x86_64-unknown-linux-musl/release/tillandsias" "$X86_64_DEST"
```

(plus the aarch64 twin), or `cargo build --message-format=json` artifact
parsing if we want it airtight.

## Verifiable closure

Run the script under `CARGO_TARGET_DIR=$(mktemp -d)` after touching a source
file: `--verify` must pass and the staged binary's `--version` must equal
`VERSION`.
