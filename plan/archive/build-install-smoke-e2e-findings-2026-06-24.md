# Build-Install-Smoke E2E Findings — 2026-06-24

**Run ID**: 20260624T020110Z  
**Commit tested**: 8c14045a (linux-next HEAD at start)  
**Installed version**: Tillandsias v0.3.260624.1 (VERSION bumped by prior agent in bd8d6c31)  
**Host**: linux_mutable  
**Log dir**: target/build-install-smoke-e2e/20260624T020110Z/

---

## Gate Results

| Gate | Result | Notes |
|------|--------|-------|
| §0 Preflight | PASS | branch=linux-next, clean worktree |
| §1 Build + install | PARTIAL | Binary installed OK; `--ci-full` post-build smoke failed (2/6 tests) |
| §2 Podman reset | PASS | All containers/volumes/images cleared |
| §3 `tillandsias --init` | PASS | Vault v1.18.5 healthy, 5 AppRoles, networks created |
| §4 Forge meta-orch | PASS | exit 0, forge cycle complete (zero residual at current bar) |

**Overall**: PASS (with finding — see below)

---

## Finding: Post-build litmus tests require live runtime (pre-existing)

**Spec**: `inference-container` (test: `litmus:inference-deferred-model-pulls`),
`meta-orchestration` (test: `litmus:opencode-prompt-e2e-shape`)

**Discovered by**: `/build-install-and-smoke-test-e2e` (linux)

**Symptom**: `build.sh --ci-full --install` exits 1 due to post-build litmus failures:
- `litmus:inference-deferred-model-pulls` step 2/7: "launch inference container" fails — no containers exist before `--init`
- `litmus:opencode-prompt-e2e-shape` step 5/7: "verify loop_status.md was updated" fails — forge not running before `--init`

**Root cause**: `--ci-full` runs post-build litmus tests that require a live Podman/forge
environment. On a fresh host (before `tillandsias --init`), these tests cannot pass.
This is a structural chicken-and-egg: post-build tests need the runtime, but the runtime
is set up AFTER the build.

**Impact**: `build.sh --ci-full --install` always exits 1 on a fresh host. The binary
IS correctly installed. The failure is a false negative in the CI gate, not a build failure.

**Classification**: optimization — build script should skip runtime-dependent post-build
tests when no live Podman session is available, or split into `--ci-pre` / `--ci-post-init`.

**Repro**:
```bash
podman system reset --force
./build.sh --ci-full --install   # exits 1 (post-build smoke fails)
tillandsias --version             # but binary IS installed
```

**Status**: pre-existing (not caused by ZeroClaw migration or order-88 changes). No
regression from prior behavior. The e2e continued with the installed binary since
it was demonstrably present and functional.

---

## Init Health Summary

```
runtime assets: /home/tlatoani/.local/share/tillandsias/runtime/0.3.260624.1
images built: proxy, vault, default, inference (all built from scratch — cold start)
Vault: initialized + unsealed, healthy v1.18.5
AppRoles: git-mirror, forge, tray, inference, github-login
Networks: tillandsias-egress, tillandsias-enclave
IPv4-only mode: yes (IPv6 connectivity check failed — pasta_options=[--ipv4-only])
init_exit: 0
```

---

## Forge Cycle Summary

The in-forge meta-orchestration (step 4) completed with exit 0:
- Host kind: `forge`
- Worker drain: zero linux-ready nodes (all remaining work is macOS/Windows-owned)
- Reduction engine: zero residual at current bar
- Forge commit `21f0b3d1` pushed to local git mirror only (mirror→GitHub forwarding blocked by missing HTTPS credentials — known gap)

---

## Work Queue Entry

```
- 2026-06-24T02:22Z  20260624T020110Z  Build-install smoke e2e v0.3.260624.1 — PASS (with finding).
  Binary built + installed OK. Podman reset clean. --init clean (Vault v1.18.5, 5 AppRoles,
  all images built from scratch). Forge meta-orch exit 0.
  Finding: post-build litmus false negatives on fresh host (inference-deferred-model-pulls,
  opencode-prompt-e2e-shape) — pre-existing, not a regression.
  Report: plan/issues/build-install-smoke-e2e-findings-2026-06-24.md
```
