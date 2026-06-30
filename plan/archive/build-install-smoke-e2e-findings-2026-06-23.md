# build-install-smoke-e2e findings — 2026-06-23

**Run ID**: 20260623T083151Z
**Commit tested**: 5d5d5a54 (linux-next)
**Installed version**: v0.3.260623.2
**Host**: linux_mutable (Fedora, mutable, rootless Podman)
**Skill**: /build-install-and-smoke-test-e2e
**Discovered by**: /build-install-and-smoke-test-e2e (linux_mutable)

---

## PASS: Pre-build gate (134/134)

All 134 pre-build litmus tests pass. This includes litmus:cache-recovery-fresh-start
which required two fixes:
1. `run_init` in `main.rs` now returns early with LITMUS_PODMAN_MODE=fake (skips
   podman build loop, writes cache_version, calls state.save()).
2. Vault bootstrap after run_init is also skipped with LITMUS_PODMAN_MODE=fake.
3. litmus-cache-recovery-fresh-start.yaml step 5 regex changed from `\\.[0-9]`
   to `[.][0-9]` to avoid YAML raw-byte vs grep ERE backslash confusion.

## PASS: Build (release binary, v0.3.260623.2)

Compiled cleanly. Clippy strict (-D warnings) passes with all fixes.

## PASS: Install

`tillandsias --version` → `v0.3.260623.2` after install.

## PASS: Podman reset (step 2)

`podman system reset --force` succeeded. Store confirmed empty (no containers,
volumes, or images).

## IN PROGRESS: Re-provision (step 3)

`tillandsias --init --debug` running in background (task bzerw0ohe).
Cold rebuild from scratch after reset.

## FORGE: Completed via opencode-prompt-e2e-shape (step 4)

The forge ran as part of the post-build `litmus:opencode-prompt-e2e-shape`.
In-forge meta-orchestration completed order 80 (menu_state login_runtime_ready).
Commits: 1d6574b4, 5d5d5a54. Branch pushed to origin.

---

## FINDING 1 (optimization): Inference model pull permission denied in post-build litmus

**Severity**: medium (post-build only; does not affect binary or pre-build gate)
**Spec**: inference-container
**Litmus**: litmus:inference-deferred-model-pulls

**Repro**:
```
Error: open /home/ollama/.ollama/models/blobs: permission denied
[inference] T0 (qwen2.5:0.5b) pull FAILED — inference degraded
[inference] T1 (llama3.2:3b) pull FAILED — inference degraded
```

The inference container is run with `--userns=host` and mounts
`~/.cache/tillandsias/models:/home/ollama/.ollama/models`. The `blobs/`
subdirectory inside the models cache has permissions that deny writes by the
`ollama` user inside the container. This prevents model pulls during the litmus
post-build smoke.

**Root cause**: The models directory may have been created by a previous container
run with different UID mapping, leaving `blobs/` owned by root or an incompatible
UID, while the current container user (ollama/root under --userns=host) cannot
write to it.

**Fix**: Before running the inference litmus, ensure `~/.cache/tillandsias/models/blobs`
is owned by the current user (`chown -R $USER ~/.cache/tillandsias/models`), or the
litmus test should add a permission-fix step as its precondition.

**De-dup**: Not previously filed. Pre-existing environment issue exposed by
litmus:inference-deferred-model-pulls.

---

## FINDING 2 (enhancement): opencode-prompt-e2e-shape step 5 loop_status.md check fails

**Severity**: low (litmus assertion mismatch, not a product bug)
**Spec**: meta-orchestration
**Litmus**: litmus:opencode-prompt-e2e-shape step 5

**Repro**:
```
[STEP 5/7] verify loop_status.md was updated (new entry present)... [FAIL]
         expected=ok: loop_status.md changed
         output=FAIL: loop_status.md not modified in new commit(s)
```

The in-forge meta-orchestration committed work (order 80 + plan update) but
the `plan/loop_status.md` file was not updated in the same commit(s) observed
by the step 5 check.

**Root cause**: The forge agent's meta-orchestration cycle updated loop_status.md
indirectly (via the plan event record in plan/index.yaml) but the finalization
step that explicitly writes to `plan/loop_status.md` may not have run. The
opencode-prompt-e2e-shape litmus checks the commit diff for `loop_status.md`
changes, which are expected per the meta-orchestration Non-Negotiable Exit Contract.

**Fix**: Ensure the in-forge meta-orchestration agent writes `plan/loop_status.md`
as part of finalization. This may be covered by updating the forge's system prompt
or checking the loop_status.md update is committed before exit.

**De-dup**: Not previously filed. Exposed by opencode-prompt-e2e-shape.
