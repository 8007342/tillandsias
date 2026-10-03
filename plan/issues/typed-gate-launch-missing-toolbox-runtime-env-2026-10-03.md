# Typed gate-launch recipe omits toolbox runtime context

@trace order:1542-qkc8, order:1538-pwdr

## Measured finding

On mutable Linux host macuahuitl, 2026-10-03, source `d3ffda692`, the detached typed-door recipe in `skills/advance-work-from-plan/SKILL.md` launched `tillandsias-plan run --json --timeout-ms 5400000 -- bash <gate-script>`. The script called `TILLANDSIAS_SKIP_VERSION_BUMP=1 ./build.sh --check`. Two attempts exited1 after50452ms and50433ms, before any gate check:

```text
[tillandsias-builder] Initializing 'tillandsias-builder' with build tools...
  [dnf] Error: failed to initialize container tillandsias-builder
```

Direct toolbox entry succeeded, and the exact initialized-tool probe found every required tool and Rust target. The typed door clears its environment by design (`run_verb.rs::base_env`/`execute` and `lua_predicate.rs::PROC_RUN_BASE_ENV_PASSTHROUGH`); the recipe does not explicitly restore `XDG_RUNTIME_DIR` for toolbox.

Passing supported `--env "XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR"` through the same door made `toolbox run --container tillandsias-builder true` return `status=exited, code=0, ok=true, wall_ms=298` (run_id `947078b0-32b3-4545-9329-6390c38ebf98`). The full gate then passed: its phases totalled873s, and the enclosing door returned `status=exited, code=0` (run_id `41c7be5b-66fd-4bc9-b8b2-72144394759d`). Claim commit `12ce84ebf` was pushed and mechanically confirmed. This is Linux evidence, not an all-litmus or native Mac/Windows claim.

Each failed launch also created the empty status-visible files `toolbox/migrate.lock` and `toolbox/pkcs11.lock`. Startup was clean and creation times matched these attempts; only those exact empty cycle-owned artifacts were removed. No preexisting work, peer caches or containers were deleted.

## Bounded follow-up

Correct Linux toolbox typed-door gate recipes in the skills/runbooks to explicitly forward existing runtime context where needed. Preserve JSON status, long timeout, script-file launch, containerized build, and the operator-only supervisor boundary. Do not widen the production inherited environment, add a host-native fallback, rewrite build/landing, or infer macOS/Windows results.

Small raw receipts are retained under the parent diagnostic boundary `/tmp/opencode/lua-composition-parent-20261003.4wzwBC/tmp/future-receipts/`, pending archival in the composition checkpoint at `plan/issues/evidence/typed-gate-runtime-env-20261003/`. The boundary is scratch retention, not durability proof; this committed finding preserves the observed identities and outcomes meanwhile.1542-qkc8 is queued separately; composition1538-pwdr and tracing1539-dt84 remain the pass priorities.
