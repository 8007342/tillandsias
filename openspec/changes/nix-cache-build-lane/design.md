# Design: the nix-cache build lane (873-b1nx)

Measured on macuahuitl 2026-08-25 (RTX A5000 host; GPU idle 0% / 664 MiB
during every timing below — recorded per the contamination rule). Every
number here is a measurement, not an estimate; the commands are in the
873-b1nx event stream.

## The decision

Builds run inside a Linux container whose toolchain closure is substituted
from the enclave nix cache (`https://nix-cache:5000`, harmonia serving the
persistent chroot store with ed25519-signed narinfo). The same container
image works on all three platforms because all three already run a Linux
container substrate in the dev stack:

| platform | substrate                 | status                          |
| -------- | ------------------------- | ------------------------------- |
| Linux    | podman (host)             | measured, this document         |
| Windows  | WSL2 (the existing lane)  | deferred — cost noted below     |
| macOS    | the VFR guest VM          | deferred — cost noted below     |

Lane selection is an environment opt-in, exactly the `with-wsl2-builder`
pattern: `TILLANDSIAS_BUILD_LANE=container` routes `./build.sh` through the
builder container; unset means byte-identical current behaviour (873-b1nx
exit criterion 3). The wrapper — not the developer — owns every host-dialect
fact in this document.

## Measured answers to the packet's unknowns

**(1) Does substitution actually serve a build?** Yes, end to end, with
numbers:

- Cache-only dry-run of `.#tillandsias-x86_64-musl` against a fresh store,
  BEFORE seeding: **2,791 derivations to build, 0 fetchable** — the flake's
  pin family (rustc 1.82.0) had never been built through the shared store,
  which held 1.95/1.97-era families from other derivation sets.
- Seeding build into the served store (upstream substituters permitted for
  the seed): **113 s**.
- Cache-only dry-run AFTER seeding: **5 to build + 558 fetched (3.1 GiB),
  resolved in 6.0 s** — ~99.8 % closure coverage; the residual five are the
  project's own source-stamped derivations, the correct floor.
- **Full warm build, fresh store, enclave cache as the ONLY substituter:
  96 s wall** (563 paths copied + 5 local builds). The same target from
  source is hours; the upstream-assisted seed was 113 s.

**(2) IO through VM boundaries.** Not yet measured (the Linux lane has no VM
boundary). The with-wsl2-builder history stands as the prior: keep the store
and target dir INSIDE the guest. The WSL2/macOS measurements must reproduce
the 96 s shape before those lanes are declared.

**(3) The 8 GB floor host.** Not yet measured. If the container lane cannot
link tillandsias-headless there, the lane needs a remote-build story, not a
bigger cache; nothing in this design precludes `nix build --store ssh-ng://`
against this host later.

## Facts the wrapper must own (each cost a false reading to learn)

- **Seeding is a per-pin-family responsibility, not a hope.** One host (the
  fat host, at flake-pin bumps) runs the seeding build; every other host and
  every fresh checkout then substitutes. The lane's health metric is the
  cache-only dry-run's `fetched/built` ratio — cheap (6 s), falsifiable, and
  exactly the probe that exposed the pin skew.
- **Fedora's packaged nix pins `ssl-cert-file` as a SETTING**, which
  overrides both `NIX_SSL_CERT_FILE` and `SSL_CERT_FILE`. Consumers must
  pass `--option ssl-cert-file <nix-cache-state>/ca-bundle.crt`. curl
  verifies with the same bundle (the chain is sound: leaf SANs cover
  `nix-cache`/`localhost`/`127.0.0.1`); only the nix setting hides it. This
  single fact produced a false "0 % coverage" reading.
- **The forge image is nix-free BY DESIGN** (801-x1nx: the operator settled
  that the ephemeral tier stays cheap; the spec was corrected, not the
  image). The builder container is therefore its own LONG-LIVED-tier
  container — a sibling of nix-cache/vault/proxy in SHARED_STACK_SCOPES —
  not a forge-image variant.
- **Cache unavailability degrades to cold, never to failure.** The cache
  container was SIGTERMed twice on measurement day (880-tdwn, since closed);
  the lane falls through to upstream substituters + local build, and the
  878-79b5 supervisor restarts the cache within a cycle.

## What remains

1. The builder container itself (long-lived tier, nix + the substituter
   config above baked in, enclave network, store on a named volume).
2. `build.sh` lane selection behind `TILLANDSIAS_BUILD_LANE` with the
   byte-identical-default guarantee and a litmus pinning both branches.
3. The WSL2 and VFR measurements (or their recorded deferral with cost) —
   exit criterion 4.
