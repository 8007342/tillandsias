# Pre-Vault obsolescence audit — 2026-06-05

trace: openspec/specs/tillandsias-vault/spec.md, plan/index.yaml (steps 22, 30, 32–36),
       plan/issues/vault-hardening-architecture-2026-06.md,
       plan/issues/markdown-distillation-audit-2026-05-24.md

- **Host / branch**: linux (`linux-next`)
- **Scope requested**: linux headless spec, idiomatic podman layer, orchestration,
  security, authentication, vault, safe & debug browsers, `--github-login` + GitHub
  token lifecycle — check for **obsolete references and implementations from before
  the Vault**, then clean up `./plan`, archive completed items, add missing items,
  and report per-host work queues.
- **Method**: targeted ripgrep + full-file reads, cross-checked against the
  post-hardening `tillandsias-vault` spec and `crates/tillandsias-headless/src/main.rs`.
  (A first-pass multi-agent workflow was aborted by a transient API-529; the audit was
  completed inline. Every claim below is anchored to a `file:line` the orchestrator read.)

This note is **intake/report only** per the markdown-distillation policy. The
actionable work it surfaces is shaped into `plan/index.yaml` steps 32–36 and the
per-host queues; durable architecture lives in the cited specs, not here.

---

## 1. Executive summary

The Vault is the current secrets backend and the **core flow is sound**: `--github-login`
captures the token in a containerized `gh` session and stores it in Vault at
`secret/github/token` (`main.rs:run_github_login(debug: bool)`), per-container AppRole
tokens (1h TTL) are delivered via podman secrets, the legacy flags are *rejected*
(`main.rs:313-316`), and `secrets-management` is marked `superseded`.

The headline problem is a **completed-but-not-done hardening step**. Plan step 22
`vault-hardening-architecture` (Phase 6.5) is marked `completed` with all five sub-phases
`[COMPLETED]`, and the `tillandsias-vault` spec was rewritten to *forbid* the transitional
XOR envelope and *mandate* `vault operator rekey` + bootstrap-artifact deletion — **but
the implementation never changed for two of those phases**. The pre-Vault-hardening
design still ships. Around it sits a wide band of stale pre-Vault documentation, specs,
and test fixtures that still present the removed keyring/podman-secret path as live.

**Confirmed obsolete items by severity:** 1 blocker (release), 1 high impl-divergence,
2 high doc clusters, 1 medium active-spec cluster, 1 medium dead-code cluster.
Browsers, enclave/proxy isolation, and the orchestration control-plane are **clean**.

---

## 2. Confirmed obsolete — actionable

| Sev | Surface | Finding | Locations | Action → step |
| --- | --- | --- | --- | --- |
| 🔴 blocker | release | VERSION conflict: `71bd4d2c` bumped `linux-next` to `0.3.260603.1`; `main` at `0.2.260603.1`. PR #15 `mergeable_state: dirty`; **no tag, no v0.3.0 release**. Operator-gated (3 paths). | `plan/issues/multi-host-integration-loop-2026-05-24.md` (18:07Z escalation); `VERSION` | step 37 |
| 🟠 high | vault impl | **Step 22 claimed `vault operator rekey` + `root.token` deletion `[COMPLETED]`, but neither shipped.** entrypoint still uses the XOR `init.envelope` as the live auto-unseal and persists/re-reads `root.token`. Spec forbids both. | `images/vault/entrypoint.sh:23-33,106-167` (no `rekey`; `xor_hex`; `echo … > root.token`; `cat … root.token`); `crates/tillandsias-headless/src/vault_bootstrap.rs:617-647`; spec `tillandsias-vault/spec.md:84-95`; litmus `litmus-vault-auto-unseal-no-prompt.yaml` is `size: e2e` (never runs in instant suite → divergence invisible to "103/103 green") | step 32 |
| 🟠 high | docs | `cheatsheets/runtime/hashicorp-vault-tillandsias.md` (+ byte-identical image mirror) tells users `--init --without-vault` and `--github-login --legacy-keyring-secrets` work, and documents the pre-hardening `init.json`/`root_token` bootstrap. | repo `:29,36,40,190-191,287,358,383` + `images/default/cheatsheets/runtime/hashicorp-vault-tillandsias.md` | step 33 |
| 🟠 high | docs | `cheatsheets/utils/tillandsias-secrets-architecture.md` (+ mirror) documents the **entire** secrets model as the `tillandsias-github-token` podman-secret + `/run/secrets/tillandsias-github-token` flow; never mentions Vault (~20 refs ×2). `cheatsheets/utils/podman-secrets.md` (+ mirror) shows creating that secret. | repo + `images/default/cheatsheets/utils/{tillandsias-secrets-architecture,podman-secrets}.md` | step 33 |
| 🟡 med | active specs | `podman-secrets-integration` is **active** but describes secret integration entirely via `tillandsias-github-token` (22 refs) with **0** references to the current `vault-unseal`/`vault-token` podman secrets. | `openspec/specs/podman-secrets-integration/spec.md` | step 34 |
| 🟡 med | active specs | `tillandsias-vault` spec self-contradicts: req says legacy "completely removed" + rejection scenario, but two invariants still treat `--without-vault`/`--legacy-keyring-secrets` as reachable. | `tillandsias-vault/spec.md:253-261` | step 34 |
| 🟡 med | active specs | `secrets-management` is `superseded` but not tombstoned; body still says "for one release behind the deprecated `--legacy-keyring-secrets` flag" (now removed). `git-mirror-service/spec.md:153` keeps a `--legacy-keyring-secrets` start scenario. | `secrets-management/spec.md:10`; `git-mirror-service/spec.md:153` | step 34 |
| 🟡 med | dead code / fixtures | Unreachable legacy branches: `images/git/{entrypoint.sh:31-36,post-receive-hook.sh:107,Containerfile:36}`. Test fixtures still create the removed secret: `scripts/test-support/{github-login-fake.sh:33-40,podman-mock.sh:48}`, `methodology/litmus-framework.yaml` examples — **contradicting** `litmus-vault-github-token-capture-shape.yaml:37` which asserts the symbol is gone. Stale accountability log `secret_name="tillandsias-github-token"` + `@trace spec:secret-rotation` in `main.rs:3271-3279`; stale `Cargo.toml:72` comment. | (as listed) | step 35 |

---

## 3. Cross-platform gap (missing work, not obsolete)

The hardened `tillandsias-vault` spec mandates host-OS-keychain unseal-key storage
**on all platforms** (`spec.md:75-76`) with delivery via `vsock-transport` on
Windows/macOS. The implementation (`vault_bootstrap.rs`) is **Linux-only**. macOS/Windows
have no keychain unseal-key + `installation-uuid` vsock delivery → step 36 (depends on
step 32). This was also flagged in the now-removed root audit doc's "Operational
Hardening / Step 4".

---

## 4. Intentional tombstones / correct-as-is — DO NOT re-flag

- `secret-rotation` (`status: retired`), `host-chromium` (`status: obsolete`),
  `overlay-mount-cache`/`tools-overlay-fast-reuse`/`opencode-web-session`/`cli-diagnostics`
  tombstones — methodology preserves these.
- `security-privacy-isolation:20,27` "no … keyring handle is attached" — **correct**
  negative-isolation invariant (forge gets no keyring), not a legacy reference.
- `native-secrets-store` (active) — still **live**: host keychain stores the Vault
  unseal key (Phase 6.5) and repo SSH deploy keys (`scripts/generate-repo-key.sh`).
  Keep; only its incidental `github-token` mentions (if any) are stale.
- `chromium-safe-variant` / `chromium-debug-variant` (active) — clean, no secret
  handling, no obsolete refs. The "safe & debug browsers" surface is healthy.
- `podman-orchestration`, `enclave-network`, `proxy-container`, `reverse-proxy-internal`,
  `headless-mode` — no pre-Vault drift found.
- `podman-idiomatic-patterns:88-90` "secret created at startup from host keyring" —
  **review, low confidence**: arguably still accurate for the HKDF-derived unseal-key
  podman secret; left for step 34 to confirm rather than blindly rewrite.

---

## 5. Plan cleanup performed this cycle

- Archived completed step deliverables 24–31 → `plan/archive/2026-06-05/steps/`
  (index `deliverable:` pointers updated).
- Archived 16 zero-reference completed-wave / closed-gap / tombstone issue files →
  `plan/archive/2026-06-05/issues/` (see that dir's README). 44 still-referenced issue
  files kept in place.
- Restored the missing `plan/steps/README.md` (dangling `step_file_template` ref).
- Committed the 9 untracked `plan/diagnostics/*-summary.md` (same class as the 36
  already tracked; not gitignored).
- Distilled the still-valid finding from the **untracked** root
  `TillandsiasVault_audit_20260602T140824Z.md` (a pre-hardening Gemini audit — it
  described the XOR envelope + `--legacy-keyring-secrets` as current, which step 22
  was supposed to remove) into §2 (step 32) and §3 here, then **removed** the root doc
  per the markdown-distillation policy (untracked top-level Markdown is intake, not
  authority).
- Added steps 32–37 and refreshed per-host queues + `loop_status.md`.
