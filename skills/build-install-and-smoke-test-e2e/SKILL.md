---
name: build-install-and-smoke-test-e2e
description: Build, install, and destructively smoke-test the current Tillandsias checkout on a Linux host. Use when the repository is on `linux-next` and Codex must run `./build.sh --ci-full --install`, wipe all user Podman state, initialize the installed local build from a pristine store, and, only after every gate passes, launch the current project in the forge with `/forge-continuous-enhancement`.
---

# Build, Install, and Smoke Test End-to-End

Validate the current `linux-next` checkout as a locally built operator workflow.
Run every gate in order and stop at the first failure.

## Destructive operation

This skill intentionally runs:

```bash
podman system reset --force
```

That command irreversibly deletes all Podman containers, images, volumes,
networks, and secrets for the current user. The operator selected this skill
with that behavior understood. Do not ask for confirmation before the reset.

## 0. Preflight

Run from the Tillandsias repository root. Refuse to continue unless all guards
pass:

```bash
test "$(uname -s)" = Linux
test "$(git branch --show-current)" = linux-next
test "$(pwd -P)" = "$(git rev-parse --show-toplevel)"
test -x ./build.sh
```

Do not switch branches automatically. A dirty checkout is a valid local build
target; record it and never modify, discard, or hide existing changes.

Create a fresh evidence directory without deleting earlier runs:

```bash
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
LOG_DIR="target/build-install-smoke-e2e/$RUN_ID"
mkdir -p "$LOG_DIR"
git rev-parse HEAD | tee "$LOG_DIR/00-commit.txt"
git status --short | tee "$LOG_DIR/00-status.txt"
```

## 1. Build and install

```bash
./build.sh --ci-full --install 2>&1 | tee "$LOG_DIR/01-build-install.log"
BUILD_RC=${PIPESTATUS[0]}
printf 'build_install_exit=%s\n' "$BUILD_RC" \
  | tee "$LOG_DIR/01-build-install-exit.txt"
test "$BUILD_RC" -eq 0
hash -r
command -v tillandsias | tee "$LOG_DIR/01-installed-path.txt"
tillandsias --version | tee "$LOG_DIR/01-installed-version.txt"
```

If the build, CI, install, path lookup, or version probe fails, stop. Do not
reset Podman because no valid local build was installed.

## 2. Reset Podman

Run the destructive reset immediately without another confirmation:

```bash
podman system reset --force 2>&1 | tee "$LOG_DIR/02-reset.log"
RESET_RC=${PIPESTATUS[0]}
printf 'reset_exit=%s\n' "$RESET_RC" | tee "$LOG_DIR/02-reset-exit.txt"
test "$RESET_RC" -eq 0
```

Verify that the user store is empty:

```bash
CONTAINERS="$(podman ps -aq)"
VOLUMES="$(podman volume ls -q)"
IMAGES="$(podman images -q)"
{
  printf '%s\n' '[containers]'
  printf '%s\n' "$CONTAINERS"
  printf '%s\n' '[volumes]'
  printf '%s\n' "$VOLUMES"
  printf '%s\n' '[images]'
  printf '%s\n' "$IMAGES"
} | tee "$LOG_DIR/02-empty-store.txt"
test -z "$CONTAINERS"
test -z "$VOLUMES"
test -z "$IMAGES"
```

Any listed container, volume, or image fails the reset gate.

## 3. Initialize from a pristine store

Use the installed binary produced by Step 1:

```bash
tillandsias --init --debug 2>&1 | tee "$LOG_DIR/03-init.log"
INIT_RC=${PIPESTATUS[0]}
printf 'init_exit=%s\n' "$INIT_RC" | tee "$LOG_DIR/03-init-exit.txt"
test "$INIT_RC" -eq 0
```

Inspect the log and runtime state for panics, build failures, failed or exited
containers, Vault initialization/unseal errors, registry pulls for images that
should exist locally, and enclave health failures. If init is not healthy, stop
and do not launch the forge.

## 4. Run continuous enhancement in the build forge

Remain at the current Tillandsias repository root so `.` identifies this
project. The repository skill is named `/forge-continuous-enhancement`
(singular).

```bash
tillandsias . --opencode \
  --prompt "Use the /forge-continuous-enhancement skill" 2>&1 \
  | tee "$LOG_DIR/04-forge-continuous-enhancement.log"
FORGE_RC=${PIPESTATUS[0]}
printf 'forge_exit=%s\n' "$FORGE_RC" | tee "$LOG_DIR/04-forge-exit.txt"
test "$FORGE_RC" -eq 0
```

Allow the in-forge agent to complete its skill, including filing and pushing
its plan work packets. Do not terminate it merely because it runs for a long
time.

## Findings and report

Report the commit tested, installed version, evidence directory, and the result
of every reached gate. On failure, include the failing command, exit code, and
the smallest useful log excerpt.

For each distinct product issue, de-duplicate against `plan/issues/` and file a
ready work packet using the repository's existing smoke-report conventions.
Use `discovered_by: /build-install-and-smoke-test-e2e`, cite evidence from
`$LOG_DIR`, redact secrets, and update the Linux work-queue ledger. A clean run
still gets a one-line PASS entry so the tested commit is recorded.

Commit and push only finding and ledger files to `linux-next`. Do not implement
product fixes during this skill, push directly to `main`, or open a release PR.
