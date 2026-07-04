# Forge Validation Findings: In-Forge Runtime, Tooling, and Plan Handoff Gaps

**Filed**: 2026-07-04T04:18Z  
**Origin**: Codex `/meta-orchestration` validation inside Tillandsias forge  
**Host**: `TILLANDSIAS_HOST_KIND=forge`, branch `linux-next`  
**Classification**: enhancement/optimization/research  
**Status**: pending Tlatoani approval

## Summary

This forge can fetch/push through the forge git mirror, compile the Rust
workspace, reach the network through the proxy, and talk to Vault and local
inference. It is not eligible for destructive local-build e2e because `podman`
is absent inside the forge. A full workspace test run exposed two
forge-specific test failures that future agents should fix or explicitly mark
host-ineligible.

## Validation Evidence

- `scripts/check-credential-channel.sh`: `ok:forge-git-mirror`
- `git push --dry-run origin linux-next`: `Everything up-to-date`
- `scripts/e2e-preflight.sh eligibility`: `skip:no-podman-binary`
- `cargo check --workspace`: PASS
- `cargo test --workspace --no-fail-fast`: FAIL, one failed target:
  `-p tillandsias-headless --bin tillandsias`
- `cargo test -p tillandsias-headless --bin tillandsias --no-fail-fast`:
  109 passed, 2 failed, 1 ignored
- Vault probe: `https://vault:8200/v1/sys/health` returned
  `initialized=true`, `sealed=false`, Vault `1.18.5`
- Inference probe: `http://inference:11434/api/tags` returned local models
  `llama3.2:3b` and `qwen2.5:0.5b`
- External HTTPS probe through forge proxy env:
  `curl https://api.github.com/rate_limit` returned HTTP JSON successfully

## Findings

### 1. Headless forge test misidentifies the in-container workspace target as host HOME

Failure:

```
tests::launch_forge_agent_does_not_mount_user_home
argv contains host $HOME (/home/forge) outside of HOME env: /tmp/project:/home/forge/src/alpha:rw
```

Inside this forge, `$HOME` is `/home/forge`, which is also the intentional
container-side workspace target prefix. The test currently rejects any argv
argument containing `$HOME` unless it starts with `HOME=`, so it false-positives
on the allowed bind target `/home/forge/src/<project>`.

Smallest next action: split bind args into source/target halves before checking
for host-home leakage. Reject `$HOME` only on the source side, and explicitly
allow the target side under `/home/forge/src/`.

Verifiable closure: `cargo test -p tillandsias-headless --bin tillandsias
launch_forge_agent_does_not_mount_user_home` passes inside the forge and still
fails a fixture that mounts host `$HOME/.config` or `$HOME/.cache`.

### 2. Forge image lacks the `openssl` CLI needed by `ensure_ca_bundle`

Failure:

```
tests::source_built_init_and_status_check_smoke_uses_fake_podman
ensure_ca_bundle: "Failed to run command: No such file or directory (os error 2)"
```

The code path at `crates/tillandsias-headless/src/main.rs` shells out to
`openssl req` to generate the intermediate CA. This forge image has
`update-ca-trust` and `trust`, and startup provides
`/tmp/tillandsias-combined-ca.crt`, but `command -v openssl` returns nothing.

Smallest next action: either install the `openssl` CLI in the forge image or
teach `ensure_ca_bundle`/the test to use an already-injected forge CA bundle
when running inside `TILLANDSIAS_HOST_KIND=forge`. Installing the CLI is the
lowest-risk fix if the runtime code still relies on shelling out.

Verifiable closure: `command -v openssl` succeeds in a fresh forge and
`cargo test -p tillandsias-headless --bin tillandsias
source_built_init_and_status_check_smoke_uses_fake_podman` passes.

### 3. Forge e2e preflight is blocked by missing `podman`

The meta-orchestration e2e gate correctly skipped local-build e2e:

```
skip:no-podman-binary
```

This is expected for the current forge, but it means forge agents cannot
self-validate the destructive build/install/reset/init path they often touch.

Smallest next action: decide whether the forge should remain a non-Podman build
environment or gain a narrow Podman/socket capability for self-smoke. If it
remains intentionally non-Podman, add a first-class forge validation profile
that runs the maximal eligible checks and records `skip:no-podman-binary` as an
expected outcome.

Verifiable closure: either `scripts/e2e-preflight.sh eligibility` returns
`eligible` in a designated forge-smoke profile, or a committed forge-validation
script emits a stable PASS/SKIP report that includes the no-Podman verdict.

### 4. Basic diagnostic tools are absent from the forge image

Missing tools observed during network and service inspection:

```
ip ss nc socat sqlite3 podman openssl
```

`/proc/net/*`, `getent`, and `curl` were enough for this cycle, but future
agents lose time rediscovering low-level network state without `iproute` and
socket helpers.

Smallest next action: add a tiny diagnostic-tool bundle to the forge image:
`iproute`, `iputils` or equivalent, `socat`, `nmap-ncat` or equivalent,
`sqlite`, and `openssl`.

Verifiable closure: a forge image litmus asserts `command -v ip ss nc socat
sqlite3 openssl` succeeds, and a diagnostic smoke can print routes, listening
sockets, and TCP reachability without falling back to `/proc` parsing.

### 5. Plan handoff docs point at `plan/issues/ACTIVE.md`, but the file is absent

`plan/issues/README.md`, `plan/loop_status.md`, and `.forge-startup-context.md`
all reference `plan/issues/ACTIVE.md`. In this checkout the file does not exist.
Agents therefore have to infer active work from `plan/index.yaml` and loop notes,
which is slower and error-prone.

Smallest next action: either restore `plan/issues/ACTIVE.md` as the curated
active-work index, or update all references to the canonical current source.

Verifiable closure: `test -f plan/issues/ACTIVE.md` passes and the file lists
current active/blocked packets, or `rg 'plan/issues/ACTIVE.md'` returns no stale
references.

### 6. Startup context can be stale after branch switches

The forge startup context reported:

```
Branch: main
Version: 0.3.260704.2
```

The meta-orchestration contract then switched to `linux-next` for plan writes.
The context file is useful, but agents may incorrectly trust the branch field
after required orchestration branch changes.

Smallest next action: add a note to the startup context that branch is a startup
snapshot, or refresh the context after the skill switches branches.

Verifiable closure: a forge session launched on `main` then switched to
`linux-next` either updates `.forge-startup-context.md` or records the branch
field as `startup_branch`.

## Nice-To-Have Improvements

- Add a single `scripts/forge-validate.sh` that runs the eligible validation set:
  credential guard, git dry-run push, e2e eligibility, workspace check, targeted
  forge service probes, and a stable PASS/SKIP/FAIL report.
- Expose service health in one command inside the forge:
  git mirror reachable, proxy present, Vault health, inference tags, outbound
  HTTPS through proxy.
- Keep `/opt/cheatsheets` populated or remove/redirect
  `TILLANDSIAS_CHEATSHEETS=/opt/cheatsheets`; this path was empty while
  `/opt/cheatsheets-image` had content.

