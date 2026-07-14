# Windows guest-binary embed: stale target-guest/ staging silently ships an old headless (2026-07-12)

- class: optimization (build staging / version-skew guard)
- found by: windows meta-orchestration cycle (windows-bullo-fable5-20260712T1940Z),
  order-297 destructive cold-provision e2e
- status: open
- trace: scripts/build-windows-tray.ps1 (guest-binary embed, order 190/282),
  scripts/build-guest-binaries.sh staging contract

## Symptom

A fresh `windows-next@7eaa8319` tray build (host VERSION 0.3.260712.1)
embedded and injected a guest headless of **v0.3.260711.8** into the freshly
provisioned WSL guest. The embed step compares content hashes between
`target-guest/` and the crate asset ("Guest binary already staged
(unchanged)") but nothing checks the staged binary's VERSION against the
checkout, so a stale `target-guest/` propagates silently. The header comment
claims the embed avoids version skew (vs the guest release-fetch fallback) —
it actually introduces a quieter variant: guest one release behind the host
with no warning.

Consequence this session: the injected guest predated the order-298 headless
fix (pristine-first-launch proxy teardown) — the exact class the attended
smoke was about to exercise. Worked around by downloading the published
v0.3.260712.1 musl asset (SHA-verified against the release SHA256SUMS),
restaging `target-guest/`, and hot-swapping /usr/local/bin in the guest +
unit restart (guest now reports v0.3.260712.1, wire reconnected Ready).

## Update (same session): order 282 already pinned this — at TEST time

`wsl_lifecycle::tests::embedded_guest_headless_matches_workspace_version`
(order 282) correctly fails on the stale embed — confirmed live once
`cargo test -p tillandsias-windows-tray` ran. The actual gap is narrower
than first filed: `scripts/build-windows-tray.ps1` only cargo-BUILDS, so
the pin test never runs on the quick build+install path and the skewed exe
ships anyway. Restaging `target-guest/` + assets with the current release
binary turns the test green. Remaining fix: make the BUILD script itself
fail (or warn loudly) on embed/VERSION mismatch — e.g. run that single
test, or compare the version string in the staged binary — so the gate
exists where the artifact is produced, not only in --ci-full.

## Fix direction

At embed time, extract the staged binary's version (`--version` is not
runnable on Windows; instead record a sidecar `target-guest/<name>.version`
in the staging contract, or grep the embedded version string) and WARN (or
fail with an override env) when it does not match the checkout VERSION.
Also print the staged version in the build output either way — the silent
"unchanged" is what hid the skew.

## Repro

Stage a guest binary, bump VERSION (or merge a release), rebuild the tray:
build prints "already staged (unchanged)" and embeds the old headless.
