# P1: headless re-ensure regenerates a NON-matching vault unseal secret on restart → barrier orphaned, crash-loop (restart self-wedge)

- Date: 2026-07-17
- Class: bug (P1, vault lifecycle; restart-triggered self-wedge of the barrier)
- discovered_by: windows-bullo-fable5-20260717 (Windows lane, real operator
  secrets) while rerunning the BigPickle goal on a build carrying order 383
- pickup_role: linux (vault_bootstrap / ensure_vault_running secret-creation path)
- Related: order 383 (root-token generate-root self-heal — DIFFERENT layer;
  383 correctly escalated on the deeper skew below),
  `litmus-mock-podman-keychain-pollution-2026-07-17.md` (same credential-source
  pollution class), order 309 (guest least-privilege).

## What happened (live, reproduced)

The operator's vault had been healthy for ~1h (unsealed in memory). Deploying
the order-383 fix by HOT-SWAPPING the guest headless binary
(v0.3.260716.5 → .7) and `systemctl restart tillandsias-headless` triggered
the liveness re-ensure. That re-ensure **regenerated the podman secret
`tillandsias-vault-unseal`** (podman secret UPDATED timestamp = restart time;
storage `vault-data` init timestamp = 43h earlier). The new secret did NOT
match the existing storage's master key, so the vault entrypoint's unseal
call returned `curl: (22) HTTP 400` and the container crash-looped
(`exited (22)`, health 125). Because vault was down, liveness kept
re-ensuring — regenerating the secret every cycle — a self-sustaining wedge.

Net: a previously-healthy vault is wedged by a restart, and the operator's
real secrets (GitHub token in KV) become unreadable until manual recovery.

## Root cause boundary (two distinct layers — do not conflate)

1. **Barrier unseal (THIS packet, P1)**: the re-ensure wrote an unseal
   secret that does not unseal existing storage. The intact fallback share
   `~/.cache/tillandsias/fallback_vault-shamir-share-v1` (44B base64 → 32
   raw bytes, mtime identical to storage init to the same second) IS the
   correct barrier key: recreating the podman secret from it (exactly 32
   raw bytes, no trailing newline) + replaying the container's own
   `--replace` create-command unsealed the vault cleanly (`sealed:false`,
   healthy). So the correct key was available; re-ensure sourced/wrote the
   WRONG one. Fix direction: on re-ensure, NEVER regenerate the unseal
   secret when storage already exists — reuse the matching key, and if the
   only available key fails to unseal, FAIL LOUD (do not loop) with the
   attended-recovery verdict. Guard the secret-creation path the way 383
   guarded the handover pair (`handover_pair_is_persistable`): a unseal
   secret that cannot unseal extant storage must not be written/kept.

2. **Root-token generate-root (order 383, WORKED)**: once the barrier was
   recovered, headless restart ran the 383 seam. It detected the stale
   cached root token (403 lookup-self), attempted generate-root from the
   stored Shamir share, and the share FAILED authentication:
   `root generation aborted: unable to retrieve stored keys: invalid key:
   failed to decrypt keys from storage: error decrypting seal wrapped
   value / error decrypting using seal shamir: cipher: message
   authentication failed`. The seam then emitted the designed loud
   verdict — **OPERATOR ACTION REQUIRED** — and left storage untouched.
   This is order 383 working exactly as specified (the 2026-07-17 approle/KV
   wrinkle escalation). It is NOT a bug; it is the correct safe escalation
   for a deep key skew.

## The deep skew (attended-only, for the operator)

The barrier unsealed with the fallback key, yet generate-root's decrypt of
the STORED keys fails auth with (apparently) the same share source. That
inconsistency (barrier-unseal OK, stored-key-decrypt fail) means this
vault's key material is skewed at a layer generate-root cannot bridge —
consistent with an earlier credential-source pollution
(`litmus-mock-podman-keychain-pollution-2026-07-17.md`). Recovery is
operator-attended: a storage-preserving re-init using the true unseal key,
or (if the stored root key is unrecoverable) an attended re-init that
re-seeds the KV secrets from the operator's sources. The GitHub token KV
data is NOT deleted — it is in the intact `vault-data` volume, currently
undecryptable via the skewed stored-key path.

## Current state left for the operator (this cycle)

- Vault BARRIER recovered: `tillandsias-vault` Up/healthy, `sealed:false`,
  storage + fallback share intact. Control wire REACHABLE, phase Ready —
  the tray is usable again.
- Root-token / KV writes still blocked pending attended recovery (layer 2).
- No storage was wiped; no share was overwritten by this session (the
  root-token cache file was briefly truncated by an early botched manual
  command and regenerated — non-critical, the barrier key lives in the
  share file).

## Deploy-method note (contributing factor)

Binary hot-swap is NOT the supported deploy path — it left the runtime
assets/images at mixed versions and triggered the re-ensure that exposed
this bug. The supported path is a full tray install of a build carrying the
fix, which materializes assets and brings the stack up coherently. But the
underlying re-ensure-regenerates-unseal-secret bug is real and
restart-triggerable independent of hot-swap; a version-matched restart
could hit it too. File stands as P1.

## Verifiable closure

- Fixture/litmus: with an initialized vault storage and a DIFFERENT unseal
  key offered to the re-ensure, ensure MUST NOT overwrite the working
  secret nor crash-loop; it must reuse the matching key or emit the
  attended verdict once (no loop).
- The order-383 escalation grammar (OPERATOR ACTION REQUIRED, storage
  untouched) already pins layer 2; this packet pins layer 1.
