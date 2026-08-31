# nix's bundled libcurl cannot verify TLS behind the transparent proxy (order 920-tybk)

- Date: 2026-08-28
- Filed by: linux-macuahuitl-claude-20260828t195711z (audit-drain of BigPickle commit 3d56d69b6)
- Branch: linux-next
- Packet: `nix-bundled-libcurl-cannot-verify-tls-behind-transparent-proxy` (order 920-tybk)

## Symptom

The nix binary tarball bundles its own glibc + libcurl + OpenSSL. Behind this
environment's transparent proxy (TLS interception), that bundled stack CANNOT
verify github.com's certificate — every direct flake-input fetch fails on SSL
verification — while **system curl on the same host succeeds against the same
URLs**. The trust store the proxy's CA was installed into is the system one;
nix's bundled OpenSSL never consults it.

## Measurement regime — READ BEFORE GENERALIZING

Observed by BigPickle on **lenovinha**, **n=1**. Regime: Linux host behind the
ayahuitlcalpan transparent proxy with TLS interception; nix installed from the
binary tarball (bundled userland, not distro-packaged); nix 2.35.2 inside the
`nix/builder/Containerfile` image. NOT yet reproduced on a second host, NOT
tested with distro-packaged nix (which links the system libcurl/OpenSSL and
plausibly does not have this defect), NOT tested off-proxy. Per
`attach-the-regime-before-broadcasting`: do not relay this as "nix cannot fetch
on the fleet" — it is one host, one install method, one network regime.

## Workaround (landed in 3d56d69b6)

`scripts/nix-build-container.sh` (run via `scripts/with-nix-builder.sh`):
parse every input out of `flake.lock` with jq, prefetch each GitHub tarball
with **system curl** (which trusts the proxy CA), extract locally, and pass
`--override-input` for every input so nix never touches github.com directly.
Dependencies substitute from cache.nixos.org (which works — the failure is
certificate verification against the intercepted github.com endpoint, not all
TLS), and local builds complete.

## Blast radius

- Any nix invocation that resolves flake inputs from github.com on an
  affected host/regime: cold `nix build`, `nix flake update`, CI lanes that
  re-lock.
- The container build lane (873-b1nx wiring) inherits the prefetch dance and
  its complexity: ~100 lines of jq/curl that exist only to route around the
  bundled stack.
- NOT affected: cache.nixos.org substitution (observed working), system curl
  consumers, distro-packaged nix (expected unaffected — unverified).

## Smallest fix

Point nix's bundled stack at the system trust store instead of pre-fetching:
set `NIX_SSL_CERT_FILE` (and/or `ssl-cert-file` in nix.conf) to the host CA
bundle that includes the proxy CA — the same pitfall already recorded for
Fedora in `openspec/changes/nix-cache-build-lane/design.md` (the
`ssl-cert-file` setting). If that single setting makes a direct
`nix flake prefetch` of a github.com input succeed on lenovinha, the entire
prefetch + `--override-input` layer of `nix-build-container.sh` becomes dead
weight and should be retired. Verify on the affected regime first; keep the
workaround until the fix is measured there.

## Caveat

Everything above inherits the n=1 regime. The packet's exit is: reproduce (or
fail to) on a second host, test the `NIX_SSL_CERT_FILE` fix in the affected
regime, and either retire the prefetch layer or document why it must stay.
