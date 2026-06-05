# Step 33 — Pre-Vault documentation cleanup (cheatsheets + mirrors)

- **Status**: ready
- **Owner host**: linux
- **Branch**: linux-next
- **Depends on**: [] (independent of step 32; do not block on it)
- **Specs**: tillandsias-vault, secrets-management (superseded)

## Goal

Three runtime/utils cheatsheets still teach the **pre-Vault** secrets model and tell users
that removed flags work. Each is baked byte-for-byte into the forge image, so the repo copy
and the `images/default/cheatsheets/...` mirror MUST change together (enforced by
`litmus:cheatsheet-host-image-sync` — diff must stay clean).

## Targets (repo + image mirror = 2 files each)

1. `cheatsheets/runtime/hashicorp-vault-tillandsias.md` — remove `--init --without-vault`
   (`:36`) and `--github-login --legacy-keyring-secrets` (`:40`) as valid commands; drop the
   "legacy keyring path … removed in v0.3" framing (`:29,:383`); replace the `init.json`/
   `root_token` bootstrap walkthrough (`:190-191,:287,:358`) with the rekey-based flow once
   step 32 lands (or describe current state + cross-link step 32 if landing first).
2. `cheatsheets/utils/tillandsias-secrets-architecture.md` — currently documents the
   **entire** secrets architecture as the `tillandsias-github-token` podman secret +
   `/run/secrets/tillandsias-github-token`, with no mention of Vault (~20 refs). Rewrite to
   the Vault model (token at `secret/github/token`, AppRole per-container `vault-token`,
   forge gets none) or tombstone-and-replace.
3. `cheatsheets/utils/podman-secrets.md:337-358` — remove the "create
   `tillandsias-github-token` podman secret" recipe; show the current `vault-unseal` /
   `vault-token` podman-secret usage instead.

Also reconcile `docs/cheatsheets/git-mirror-lifecycle-audit.md:33,168,479,701,781`
(`--legacy-keyring-secrets` "deprecated fallback" — now removed). `docs/cheatsheets/` is
not image-baked, single copy.

## Tasks

- [ ] Update `hashicorp-vault-tillandsias.md` (repo + image mirror, byte-identical).
- [ ] Rewrite/replace `tillandsias-secrets-architecture.md` (repo + image mirror).
- [ ] Update `podman-secrets.md` (repo + image mirror).
- [ ] Update `git-mirror-lifecycle-audit.md`.

## Acceptance evidence

- `diff -qr --exclude=.gitkeep cheatsheets images/default/cheatsheets` clean.
- `./scripts/check-cheatsheet-tiers.sh --strict` PASS; `litmus:cheatsheet-host-image-sync` PASS.
- No remaining user-facing claim that `--without-vault` / `--legacy-keyring-secrets` work.
