# Forge trust: runtime proxy CA not mounted at forge launch -> vendor-roots fallback (CA source readiness gap)

- class: bug
- area: forge trust / CA readiness
- owner: linux (headless CA gen + forge launch); macOS-observed
- status: open (root-cause traced read-only; NO code change in this packet)
- found_by: live macOS forge launch (operator smoke, 2026-07-23) + read-only code trace
- branch-observed: osx-next
- relates_to (RELATED but DISTINCT):
  - plan/issues/macos-tray-github-login-stuck-no-prompt-refresh-2026-07-23.md (login CA relabel fix; main.rs:6941; commit 1dda3032)
  - plan/issues/vm-proxy-ca-tmpfs-restart-fragility-2026-07-06.md (CA source on tmpfs /tmp/tillandsias-ca)
  - plan/issues/forge-runtime-ca-trust-convergence-2026-07-14.md (the vendor-roots fallback is by-design for standalone inspection)

## Symptom

A live macOS forge launch printed:

    [trust] WARNING: runtime proxy CA is not mounted; using vendor roots only

(`images/default/lib-common.sh:47`). The forge's runtime trust bundle was composed from Fedora vendor roots ONLY; the per-install proxy (enclave intermediate) CA was not folded in, so the forge does not trust proxy-bumped TLS.

## Evidence (file:line)

- `images/default/lib-common.sh:34` -- `init_runtime_ca_trust` gates on `[ -r "$runtime_ca" ]` where `runtime_ca=/run/tillandsias/ca-chain.crt`. When that path is not a readable file it takes the else branch...
- `images/default/lib-common.sh:47` -- ...and emits the WARNING, then composes a vendor-roots-only bundle (`cp "$vendor_bundle" "$temporary_bundle"`). A missing/unreadable runtime CA is a SOFT fallback, not a hard error.
- `crates/tillandsias-headless/src/main.rs:4743-4747` -- `build_opencode_forge_args` UNCONDITIONALLY adds `--mount type=bind,source=<certs_dir>/intermediate.crt,target=/run/tillandsias/ca-chain.crt,readonly=true`. The mount source is `certs_dir.join("intermediate.crt")`.
- `crates/tillandsias-headless/src/main.rs:4668` -- the forge container is created with `--security-opt=label=disable`.
- `crates/tillandsias-headless/src/main.rs:1022` -- `const CA_DIR: &str = "/tmp/tillandsias-ca";` -- the CA source directory lives on tmpfs (`/tmp`).

## This is NOT the SELinux relabel class (distinct from the login-stuck fix)

The forge container has `--security-opt=label=disable` (main.rs:4668) -> it runs unconfined, so a PRESENT source file bind-mounted at `/run/tillandsias/ca-chain.crt` is readable regardless of the source's SELinux label. That is categorically different from the login container:

- The ephemeral `tillandsias-<provider>-login-<pid>` container (main.rs:6951-6970) is SELinux-CONFINED (`--cap-drop=ALL --security-opt=no-new-privileges --userns=keep-id`; NO `label=disable`). Its CA mount therefore needed `relabel=shared` (main.rs:6941, commit 1dda3032, plan/issues/macos-tray-github-login-stuck-no-prompt-refresh-2026-07-23.md) -- without it the PRESENT CA was UNREADABLE by container_t and vault-cli's require_cacert() gate tripped.

So the forge's failure is NOT "present-but-unreadable-due-to-SELinux-label". It is "source not a valid/current PEM at forge (re)create". RELATED theme (CA readiness), DISTINCT mechanism.

## Trace result -- the primary launchers DO call ensure_ca_bundle before the mount

Correction to the initial "the forge path never calls ensure_ca_bundle" hypothesis: it DOES on the observed path. The macOS tray execs `tillandsias-headless --opencode <path>` inside the Fedora guest (`crates/tillandsias-macos-tray/src/diagnose.rs:1196-1202`), which enters `run_opencode_mode` (main.rs:8694). BOTH production opencode launchers call `ensure_ca_bundle(debug)?` and pass the SAME `certs_dir` into `build_opencode_forge_args`:

- CLI: `ensure_ca_bundle` main.rs:8730 -> `build_opencode_forge_args(..., &certs_dir, ...)` main.rs:8916.
- Web: `ensure_ca_bundle` main.rs:9837 -> `build_opencode_forge_args(..., &certs_dir, ...)` main.rs:9998.

(Confirmed these are the only two production callers; the rest are inside `mod tests`, main.rs:12679+.) `ensure_ca_bundle` (main.rs:2108) generates `<CA_DIR>/intermediate.{crt,key}` via openssl and publishes atomically (rename, main.rs:2243-2246). The macOS `--opencode` preamble does NOT set `TILLANDSIAS_HOST_KIND=forge` (diagnose.rs:1196-1202), so the early-return at main.rs:2112-2116 is NOT taken and generation runs. So on a clean cold launch the source IS materialized before the mount -- mirroring the login path's ensure-before-mount (main.rs:6939 -> 6948). A simple "missing call" is therefore NOT the cause on the observed path.

## Root cause -- tmpfs-anchored, ungated, soft-fallback CA source (no ready-by-construction guarantee)

The residual readiness gap is STRUCTURAL, not a single missing call:

1. The mount SOURCE lives on VOLATILE tmpfs (`CA_DIR = /tmp/tillandsias-ca`, main.rs:1022). Per plan/issues/vm-proxy-ca-tmpfs-restart-fragility-2026-07-06.md, `/tmp/tillandsias-ca/intermediate.{crt,key}` is wiped on VM reboot/teardown; only an `ensure_ca_bundle` / `ensure_proxy_running` pass regenerates it.
2. The forge mount is added UNCONDITIONALLY with NO host-side readiness/validity gate (main.rs:4743-4747) -- nothing asserts the source is a current, valid PEM before the forge is created.
3. The only check is INSIDE the container and it DEGRADES rather than fails (lib-common.sh:34,47) -- the by-design "standalone inspection" fallback documented in plan/issues/forge-runtime-ca-trust-convergence-2026-07-14.md, which SILENTLY masks a stack-connected forge that has lost proxy trust.

Consequently ANY launch surface that reaches forge (re)create without a fresh, valid, same-mount-namespace source degrades silently to vendor roots. Because `--mount type=bind` on a truly absent source would fail container-create (no start, no warning), the observed "container started AND warned" implies the source was present-but-not-a-readable-PEM-regular-file at create time (e.g. the CA_DIR existing as a bare directory, or a stale/rotated/namespace-mismatched source), consistent with these surfaces:

- Shared-stack / concurrent-forge reuse: the running proxy pins the OLD CA inode (convergence doc, "Existing containers pin the mounted CA inode until restart") while a later `ensure_ca_bundle` 30-day rotation (main.rs:2186-2187) or `/tmp` churn produces a mismatched/absent source for the new forge.
- tmpfs wipe between CA generation and forge (re)create (VM reboot; the vm-proxy-ca-tmpfs class).
- Lower-probability on the macOS `--opencode` path (preamble does not set HOST_KIND), but present system-wide: any env where `ensure_ca_bundle` early-returns UNGENERATED because `TILLANDSIAS_HOST_KIND=forge` is in scope (main.rs:2112-2116).

## Impact -- spliced-fine / bumped-fails

squid runs `ssl_bump splice all` with a single bumped host (`images/proxy/squid.conf:75-79`): `release-assets.githubusercontent.com` is `ssl_bump bump`; everything else is spliced.

- SPLICED hosts (end-to-end origin TLS, validated by vendor roots): github.com, api.github.com, .githubusercontent.com, .crates.io, .pypi.org, DNF/registry mirrors (`images/proxy/allowlist.txt`). These WORK on vendor-roots-only. Builds that only fetch from spliced hosts are UNAFFECTED -> NON-BLOCKING.
- BUMPED host (proxy terminates + re-signs origin TLS with the enclave intermediate CA): `release-assets.githubusercontent.com`. Vendor roots do NOT contain the enclave CA -> TLS verification FAILS -> GitHub release-asset downloads (the transparent-caching path; e.g. large release binaries / prebuilt tool assets fetched by lib-common's install_prebuilt) BREAK inside the forge.

Net: non-blocking for spliced-host builds; breaks GitHub release-asset downloads.

## Recommended fix

Make the forge's trust source ready-by-construction and fail loud, mirroring the login path's ensure-before-mount:

1. Re-assert `ensure_ca_bundle(debug)?` (or a validity check that the source is a non-expired PEM) IMMEDIATELY before `build_opencode_forge_args` adds the mount / before every forge (re)create -- the login path already does exactly this (main.rs:6939, right before its mount at 6948). Today the opencode paths call it at the TOP of the mode fn (8730/9837), not adjacent to the create; tighten the invariant so no reattach/shared-stack-reuse surface can interpose between generation and mount.
2. Move the CA source OFF tmpfs to a persistent 0700 path (e.g. `/var/lib/tillandsias/ca`) so a VM reboot/teardown between generation and forge create cannot wipe it (the fix already recommended by vm-proxy-ca-tmpfs-restart-fragility-2026-07-06).
3. GATE forge launch on CA readiness instead of silently degrading: validate the mount source is a PEM before adding it (host-side, main.rs:4743-4747), and/or make lib-common.sh:47 a LOUD failure for stack-connected forges. The vendor-roots fallback should remain only for an explicit standalone/inspection mode, per the convergence doc's stated intent.

## Open question (recommended default)

The exact live repro surface (shared-stack reuse vs tmpfs wipe vs an unexpected source state) was not isolated in this read-only pass; the happy-path code SHOULD materialize a valid source on the observed macOS `--opencode` launch, which is itself the signal that the gap is a missing ready-by-construction guarantee rather than a single missing call. Default: implement fixes (1)+(2)+(3) regardless -- they are robust across all surfaces and cheap. If only one can land first, do (3) the host-side readiness gate: it converts every future occurrence from a silent degrade into an actionable, attributable failure.
