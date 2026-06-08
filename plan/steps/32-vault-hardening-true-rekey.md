# Step 32 — Vault hardening completion: true rekey + root.token cleanup

> **2026-06-07 UPDATE — the original target is INFEASIBLE; spec refinement required first.**
> A research+design cycle (workflow `wf_30bb6edc-012`) proved with high confidence (11 official
> HashiCorp citations) that the exit criterion "install the host HKDF key via `vault operator
> rekey`" is **impossible** — stock Vault never lets you install a chosen Shamir share. The spec
> is self-inconsistent and MUST be refined to the feasible **keychain-held Vault-generated-share**
> mechanism before implementation. A concrete spec refinement, entrypoint/vault_bootstrap plan,
> and instant guard were designed, **but the adversarial verification leg hit the session token
> limit and did not run**, so the brick-prone rewrite is NOT yet safe to land. Also confirmed: a
> real **brick bug** (`entrypoint.sh:167` cats `/vault/data/root.token` every boot; the host
> deletes it after handover → container recreate bricks Vault). Lease released. The exit criteria
> below were updated in `plan/index.yaml`. Full detail:
> **`plan/issues/vault-rekey-infeasible-finding-2026-06-07.md`**.

- **Status**: ready (blocked on spec refinement)
- **Owner host**: linux
- **Branch**: linux-next (plan) / linux-next (code)
- **Depends on**: [] (reopens the unfinished half of step 22 `vault-hardening-architecture`)
- **Specs**: tillandsias-vault

## Goal

Step 22 (Phase 6.5) marked `[COMPLETED]` and the `tillandsias-vault` spec was rewritten to
**forbid** the transitional XOR `init.envelope` and **mandate** `vault operator rekey` plus
deletion of `root.token` from the persistent volume — but `images/vault/entrypoint.sh` was
never changed for those two phases. The pre-hardening design still ships. Close the gap so
implementation matches the spec the plan already claims is met.

## Evidence of the divergence (verified 2026-06-05)

- `images/vault/entrypoint.sh:23-33` — header still states "Production must replace this
  with `vault operator rekey`"; no `rekey` call exists.
- `:106-150,159-167` — `xor_hex()` + `init.envelope` are the live persistent auto-unseal;
  `:151` `echo "$ROOT_TOKEN" > /vault/data/root.token`; `:167` `cat /vault/data/root.token`
  on every subsequent boot (so deleting it would break unseal). Only `init.json` deletion
  (`:154-155`) actually landed.
- `crates/tillandsias-headless/src/vault_bootstrap.rs:617-647` — still `podman exec cat
  /vault/data/root.token`.
- Spec `openspec/specs/tillandsias-vault/spec.md:84-95` forbids the envelope, mandates rekey,
  mandates `init.json` deletion.
- `openspec/litmus-tests/litmus-vault-auto-unseal-no-prompt.yaml` asserts `root.token`/`init.json`
  absence but is `size: e2e` — it never runs in the instant pre-build suite, so the divergence
  was invisible to the "103/103 instant PASS" signal.

## Tasks

- [ ] **rekey**: on first boot, after `vault operator init`, run `vault operator rekey`
  (or `generate-root`/rekey-init flow) to install the host HKDF-derived key as the active
  Shamir share; remove the `xor_hex`/`init.envelope` recovery path. — `images/vault/entrypoint.sh`
- [ ] **root.token cleanup**: have `tillandsias-headless` capture the root token during
  wait-for-ready, store it in the host keychain, then delete `/vault/data/root.token`;
  remove the boot-time `cat root.token` dependency. — `entrypoint.sh`, `vault_bootstrap.rs`
- [ ] **header/caveat**: delete the obsolete "PRODUCTION CAVEAT" XOR block from the entrypoint header.
- [ ] **make the contract gate**: add a fast/structural litmus (or wire the e2e one into a
  phase that runs) so a regression to the envelope/persistence is caught, not just an
  e2e test that never executes.

## Acceptance evidence

- `images/vault/entrypoint.sh` contains a `rekey` call and no `xor_hex`/`init.envelope`;
  no `root.token` survives a second boot.
- `litmus:vault-auto-unseal-no-prompt` passes against a booted vault container AND a
  structural guard runs in the instant suite. `./build.sh --check` clean.

## Notes

Code is linux-owned; do not let the entrypoint change break Windows/macOS, which inherit
the same image via the VM (see step 36 for their keychain/vsock parity).
