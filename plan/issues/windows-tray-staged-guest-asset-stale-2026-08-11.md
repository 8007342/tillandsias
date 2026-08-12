# The tray build embeds a stale staged guest without checking its version

- Order: 689-gipe
- Class: enhancement
- Filed: 2026-08-11, windows host, branch `windows-next`
- Found by: meta-orchestration cycle 2 while draining order 154; **re-framed in
  cycle 3 after the first framing turned out to be wrong** (see below)

## Observation

`cargo test -p tillandsias-windows-tray` was RED at a clean HEAD on this host:

```
test wsl_lifecycle::tests::embedded_guest_headless_matches_workspace_version ... FAILED
embedded x86_64 guest headless does not contain workspace version 0.4.260810.1 —
stale staged binary; re-run scripts/build-guest-binaries.sh then scripts/build-windows-tray.ps1
```

The embedded asset was a real 13 MB binary whose highest version string was
`0.4.260809.2` — the PUBLISHED release — against a workspace VERSION of
`0.4.260810.1`.

## The first framing was wrong

Cycle 2 filed this as "restage the asset and commit it". Both halves were wrong:

- `crates/tillandsias-windows-tray/assets/tillandsias-headless-*` is
  **gitignored** (`.gitignore:94`), as is `target-guest/` (`.gitignore:70`).
  There is nothing to commit. The asset is per-host staging state.
- Order 447 already settled what that means:
  *"staleness is HOST STAGING STATE, not a code regression … on a dev host,
  `target-guest/` routinely predates the current VERSION (any `--install` bump
  leaves it behind)"*. `scripts/build-guest-binaries.sh --verify` therefore
  skips cleanly on stale staging and fails loud only on a genuine integrity
  defect.

So a red test on a freshly cloned host is the expected steady state, not a
defect — which is its own problem (it makes the suite red by default and
drowns real failures), but it is not what needed fixing first.

## The actual gap

`scripts/build-windows-tray.ps1` decides whether to embed a staged guest by
comparing **content hashes** — "did the asset change" — and never asks whether
the staged binary is CURRENT. A stale-but-non-empty staging directory is
therefore copied into `assets/` silently, with no warning, and `include_bytes!`
embeds it. The build emits a WARN only when staging is *absent*.

The result is the dangerous direction of the failure: a tray built from a
checkout embeds a guest binary **older than its own source** and injects it into
fresh provisions. That is precisely the registered-distro version skew that
order 350's first exit criterion exists to catch. Nothing caught it at build
time; the only guard was a test assertion that a build does not run.

It also falsified an inference this host recorded earlier the same day — cycle 1
read `guest_version == tray version` as showing a rebuild had reached the guest,
which cannot follow when the tray's embedded guest is a release older than the
checkout. A correcting note is on 627-sgtt.

## Fix applied

`build-windows-tray.ps1` now scans the staged binary for the workspace VERSION
(read from the repo-root `VERSION`, the same source `build.rs` stamps into
`WORKSPACE_VERSION`, so the build-time refusal and the test-time assertion
cannot disagree about what "current" means) before copying it.

The response matches order 447's posture: refuse the **stale copy**, not the
build. The asset falls back to the zero-byte placeholder, which is the
sanctioned absent-asset path — a fresh guest fetches the published release
rather than being handed a skewed binary — and the build prints a WARN naming
`scripts/build-guest-binaries.sh`.

## Evidence

Both directions exercised on this host; the negative control is the load-bearing
half, since a check that never refuses would pass the positive case:

- **Positive** — current staging (`0.4.260810.1`): embedded as before
  (`Staged guest binary into assets (x86_64 host)`), and
  `cargo test -p tillandsias-windows-tray` went from 79 passed / 1 failed to
  **80 passed / 0 failed**.
- **Negative** — staged file replaced with a payload stamped `0.4.260809.2`:
  build printed the WARN, refused the copy, and the asset was left at **0
  bytes** (the placeholder), not the stale content.

Guest binaries restaged on this host via `scripts/build-guest-binaries.sh`
(local cargo fallback; the Nix path is unavailable here). Note for the next host
that tries it: the first attempt appeared to fail on a missing aarch64 linker,
but the cause was `$PATH` being expanded by the outer Windows shell before
reaching WSL. Both targets build fine in the `tillandsias-build` distro with
`~/.cargo/bin` and the toolchain's `rust-lld` directory on PATH.

## Residual

The second exit criterion — a tray from this checkout provisioning a guest that
reports the checkout's VERSION on a distro with **no prior Tillandsias guest** —
is not closed. This host's guest already reports `0.4.260810.1`, so
`reconcile_adopted_guest` returns early on the version match and the injection
path is not exercised. Proving it needs a clean distro, i.e. `--reset-guest`,
which wipes the vault and requires an attended re-login. Left for an operator
window rather than done unattended.

## Related

- 447 — the staleness-is-host-state ruling this fix follows.
- 683-g7p6 `forge-rebuild-silently-uses-stale-bundled-assets-not-live-source` —
  the same shape in the forge lane. Worth reading together; not a duplicate.
- 350 `windows-forge-config-trust-live-parity` — its criterion 1 is the guard
  against exactly this skew.
- 627-sgtt — the corrected inference.
