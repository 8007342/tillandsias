# Harden the Encrypted Control Channel with Per-Boot Key Derivation — Optimization — 2026-07-01

- class: optimization (security hardening)
- filed: 2026-07-01
- owner: linux
- status: pending (deferred; do NOT start before the base channel lands)
- depends_on: encrypted-control-channel-impl-2026-07-01.md (order 141)
- trace: plan/issues/encrypted-control-channel-research-2026-07-01.md (Open Decision O1, option b), plan/issues/security-audit-zero-trust-2026-07-01.md

## Why deferred

The base encrypted, version-bound channel (order 141) derives its PSK from a
**build-embedded per-release secret** only (Open Decision O1 option (a), chosen by
the operator 2026-07-01). That satisfies the version-binding requirement — only a
matching-release host and guest can complete the handshake — with zero runtime
provisioning. This packet is the operator-approved **later hardening**: mix in a
**per-boot secret** the host controls, so a leaked release secret alone no longer
lets an attacker with a matching-release binary attach across a different VM boot.

Ship the base channel first; this is a defense-in-depth increment on top of it,
not a prerequisite.

## What to add

Extend the PSK derivation from

```
PSK = HKDF-SHA256(release_root_secret, build_version, hop_id)
```

to additionally mix a per-boot secret:

```
PSK = HKDF-SHA256(
        ikm  = release_root_secret,
        salt = per_boot_secret,          # NEW
        info = "v=" || build_version || ";wire=" || WIRE_VERSION || ";hop=" || hop_id
      )
```

- **Host→guest hop:** the host generates a fresh random `per_boot_secret` per VM
  boot and injects it into the guest over a channel the host already controls and
  that precedes the vsock control wire — cloud-init user-data / kernel cmdline /
  a provisioning file staged into the guest before `tillandsias-headless`
  starts. The guest reads it once at startup, derives the PSK, and zeroizes the
  source. Now a captured release binary cannot attach to a *different* boot's
  guest without also having that boot's secret.
- **Guest→container hop:** the guest seeds each forge container's
  `per_boot_secret` via a podman secret at container creation (the guest already
  controls container launch). Domain-separated from the host↔guest secret.

## Design constraints

- **Must not weaken the version binding.** `build_version` stays in `info`; the
  per-boot secret is additive (salt), never a replacement. Mismatched versions
  still fail regardless of the per-boot value.
- **Failure-closed on a missing per-boot secret** in release mode: if the guest
  cannot read the injected secret, refuse to derive/serve (do not silently fall
  back to release-secret-only). Dev/`--debug` builds may fall back to a stable
  dev value so local host+guest still interoperate.
- **Rotation:** per-boot secret is ephemeral (new VM boot = new secret = new
  session-key space). No persistence to durable storage; zeroize after derive.
- **No secret in logs; no secret on the vsock wire** — it is delivered only via
  the pre-vsock provisioning channel, never negotiated over the channel it keys.

## Verifiable closure (done-when)

- PSK derivation mixes a per-boot secret (salt) without dropping `build_version`
  from `info`; unit test proves: (a) same build + different per-boot secret →
  different PSK (per-boot binding), (b) different build → different PSK regardless
  of per-boot value (version binding preserved).
- Host injects a fresh per-boot secret per VM boot over the pre-vsock channel;
  guest reads + zeroizes it; container hop seeds via podman secret.
- Release-mode guest with a missing/unreadable per-boot secret refuses to serve
  (failure-closed litmus); dev fallback path is dev-only.
- `./build.sh --check` and `--test` pass; e2e: two boots of the same release VM
  have distinct session-key spaces; a matching-release binary from boot A cannot
  attach to boot B.
