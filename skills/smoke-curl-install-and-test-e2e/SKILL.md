---
name: smoke-curl-install-and-test-e2e
description: Clean-room end-to-end smoke test of a PUBLISHED release. Curl-installs the latest release binary from GitHub, does a full `podman system reset --force`, runs `tillandsias --debug --init` from a pristine state, and (if init is clean) launches `tillandsias . --opencode --prompt "Use the /meta-orchestration skill"`. Every issue observed — by this skill's agent during install/reset/init, or by the agents running inside the forge under meta-orchestration — is filed as a plan/issues work packet for later pickup by /advance-work-from-plan.
---

# Smoke: Curl-Install and Test End-to-End

This skill validates that a **published release** actually works for a real
operator starting from nothing. It is the acceptance gate that catches what
`./build.sh --ci-full` cannot: problems that only appear when the signed,
downloadable artifact bootstraps the whole enclave from a wiped host substrate.

## Authority

`methodology.yaml` remains the source of truth. This skill is an executable
runbook; it does not redefine release, trace, or coordination policy. Findings
become `plan/issues/` work packets so they flow through the normal
`/advance-work-from-plan` worker loop.

---

## Host Matrix

| Host | Installer | Destructive substrate | Re-provision |
|---|---|---|---|
| immutable Linux | `scripts/install.sh` via release curl URL | `podman system reset --force` | `tillandsias --debug --init` |
| mutable Linux | `scripts/install.sh` via release curl URL | `podman system reset --force` | `tillandsias --debug --init` |
| macOS | `scripts/install-macos.sh` via release curl URL | remove Tillandsias app state/cache VM dirs | installed tray `--provision` + `--diagnose --json` |
| Windows | `scripts/install-windows.ps1` release path when available | `wsl --unregister tillandsias` plus cache purge | installed tray provision/diagnose |

This is the only e2e install skill allowed on immutable Linux.

## DESTRUCTIVE — read before running

On Linux, Step 2 runs **`podman system reset --force`**, which irreversibly
deletes ALL Podman state for this user: every container, image, volume, network,
and secret — including:

- the `tillandsias-vault-data` volume (Vault's sealed store),
- every project mirror volume (`tillandsias-mirror-*`),
- all locally built enclave images (proxy/git/inference/forge) — these get
  **rebuilt from scratch on the next `--init`, which can take many minutes**.

On Tillandsias smoke hosts, wiping Podman is expected and is a required
precondition for the release idempotence test. If
`TILLANDSIAS_DESTRUCTIVE_RESET_OK` is unset or `1`, do not ask for confirmation,
do not pause for operator timing, and do not skip Step 2 because Podman state
will be destroyed. Only block the reset when the environment explicitly sets
`TILLANDSIAS_DESTRUCTIVE_RESET_OK=0`, in which case file a plan blocker and
push it.

A fresh `--init` re-initializes Vault and re-captures the keychain-held unseal
share, so the keychain↔volume resync brick (see git history `738059bc`) is part
of what this smoke exercises — if init bricks, that is a finding, not a failure
to hide.

---

On macOS, the destructive substrate is the Tillandsias Virtualization.framework
state and cache directories. On Windows, it is the `tillandsias` WSL2 distro and
download cache.

## 0 — Pre-flight

1. **Identify host + branch** (Linux → `linux-next`, macOS → `osx-next`,
   Windows → `windows-next`). The `--opencode` forge lane is Linux/Podman today.
2. **Record the release under test:**
   ```bash
   gh release view --json tagName,publishedAt -q '.tagName + "  " + .publishedAt'
   ```
   Note the tag — every filed finding cites it so issues are attributable to a
   specific published artifact.
3. **Record sibling heads** (`main`, `linux-next`, `windows-next`, `osx-next`)
   per multi-host discipline.
4. **Create a findings log dir** the smoke will append to:
   ```bash
   mkdir -p target/smoke-e2e
   ```

---

## 1 — Curl-install the latest release

Install the published artifact the canonical way an operator would — do NOT use a
locally built `target/` binary; the whole point is to test the *download*.

Linux:

```bash
TILLANDSIAS_SMOKE_LOCK_LOG=target/smoke-e2e/00-smoke-lock.log \
  scripts/with-smoke-lock.sh --name release-smoke-e2e -- \
  bash -c 'curl -fsSL https://github.com/8007342/tillandsias/releases/latest/download/install.sh | bash' 2>&1 \
  | tee target/smoke-e2e/01-install.log
hash -r
tillandsias --version | tee target/smoke-e2e/01-version.txt
```

macOS:

```bash
curl -fsSL https://github.com/8007342/tillandsias/releases/latest/download/install-macos.sh | bash 2>&1 \
  | tee target/smoke-e2e/01-install-macos.log
"$HOME/Applications/Tillandsias.app/Contents/MacOS/tillandsias-tray" --version 2>&1 \
  | tee target/smoke-e2e/01-version.txt || true
```

Windows PowerShell:

```powershell
# Use the published Windows installer once release artifacts expose it.
# Until then, file a finding that curl-install Windows release coverage is blocked.
```

Verify the installed version matches the release tag from Step 0. If the install
script errors, the version mismatches, or `tillandsias` is not on `PATH`
afterward → **file a finding (capability: `release`, `install`) and STOP**;
the rest of the smoke is invalid on a bad install.

---

## 2 — Full substrate reset (DESTRUCTIVE — see warning above)

If `TILLANDSIAS_DESTRUCTIVE_RESET_OK=0`, stop here, write a plan blocker, and
push it. Otherwise run the reset immediately; on Linux this step is mandatory.

```bash
TILLANDSIAS_SMOKE_LOCK_LOG=target/smoke-e2e/00-smoke-lock.log \
  scripts/with-smoke-lock.sh --name release-smoke-e2e -- \
  podman system reset --force 2>&1 | tee target/smoke-e2e/02-reset.log
```

Confirm afterward that the store is empty:
```bash
podman ps -a --format '{{.Names}}'; podman volume ls -q; podman images -q
```
All three should be empty. If the reset errors or leaves residue → file a
finding (capability: `podman`, `runtime`) and note it, then continue only if the
store is actually clean.

On macOS, stop the tray and remove `~/Library/Application Support/tillandsias`
and `~/Library/Caches/tillandsias`. On Windows, run `wsl --shutdown` and
`wsl --unregister tillandsias`, tolerating an already-absent distro.

---

## 3 — Fresh init from a pristine state

```bash
TILLANDSIAS_SMOKE_LOCK_LOG=target/smoke-e2e/00-smoke-lock.log \
  scripts/with-smoke-lock.sh --name release-smoke-e2e -- \
  tillandsias --debug --init 2>&1 | tee target/smoke-e2e/03-init.log
INIT_RC=${PIPESTATUS[0]}
echo "init exit: $INIT_RC"
```

**Observe carefully.** This is the highest-signal step — a clean-room `--init`
rebuilds every image and brings up Vault from nothing. Scan `03-init.log` (and
`tillandsias --diagnostics` / container logs) for:

- non-zero exit, panics, or `Error:` lines;
- Vault failing to initialize/unseal (connection-refused loops, HTTP 400
  "cipher: message authentication failed", keychain↔volume share mismatch);
- image build failures (proxy/git/inference/forge), short-name-mode prompts,
  registry/TLS errors;
- the enclave network failing to come up;
- any container that exits non-zero (e.g. proxy SIGSEGV/139).

**File a finding for every distinct issue** (see §5). If `--init` did not reach
a healthy state, STOP here — do not proceed to Step 4; record that the smoke
halted at init and why.

---

## 4 — Forge continuous-enhancement run (only if Step 3 was clean)

```bash
TILLANDSIAS_SMOKE_LOCK_LOG=target/smoke-e2e/00-smoke-lock.log \
  scripts/with-smoke-lock.sh --name release-smoke-e2e -- \
  env TILLANDSIAS_NO_TRAY=1 tillandsias . --opencode --prompt "Use the /meta-orchestration skill" 2>&1 \
  | tee target/smoke-e2e/04-opencode.log
```

This launches the full enclave + the OpenCode agent inside the forge, which runs
[[forge-continuous-enhancement]] against the `tillandsias` checkout. Two streams
of findings come out of this step:

- **Forge-internal findings** — issues the in-forge agent surfaces while doing
  continuous-enhancement work (build warnings, slow/fragile Containerfile steps,
  failed `dnf` migrations, telemetry gaps). The forge agent should itself file
  these as plan/issues; if it cannot push from inside the enclave, capture its
  reported findings from `04-opencode.log` and file them on its behalf.
- **Harness findings** — issues YOU (the agent running this skill) observe about
  the run itself: the agent failing to launch, the prompt not being honored,
  remote-projects not listing, git-mirror push needing interactive auth, the
  maintenance/agent terminal stealing focus, vsock/control-wire version skew
  (e.g. `wire_version mismatch: server=N, sidecar=M`), etc.

File every distinct issue from both streams (see §5).

### 4b — First-launch egress assertion (order 298 regression)

While Step 4's forge lane is up (right after the agent terminal appears, or as
soon as `04-opencode.log` shows the lane container starting), assert from the
HOST that the shared proxy survived launch — v0.3.260711.8 tore down
`tillandsias-proxy` during first-launch bring-up, so every pristine install got
a forge whose baked proxy env resolved to nothing (`Could not resolve proxy:
proxy`), and the fail-soft harness installer then shipped zero harnesses:

```bash
podman ps --format '{{.Names}}' | tee target/smoke-e2e/04b-containers.txt
grep -q '^tillandsias-proxy$' target/smoke-e2e/04b-containers.txt \
  && echo "egress assertion: proxy alive alongside lane" \
  || echo "FINDING: tillandsias-proxy ABSENT while a lane container runs (order 298 regression)"
```

If the proxy is absent, also check `04-opencode.log` for the unconditional
teardown trace (`no active lane containers; cleaning project + shared stack`)
to identify the actor, and file the finding with that line as evidence.

---

## 5 — File findings as plan/issues work packets

Each finding becomes a `### Work Packet:` entry so `/advance-work-from-plan` can
claim and fix it. Append packets to a dated smoke report:
`plan/issues/smoke-e2e-findings-<RELEASE_TAG>-<DATE>.md`.

Packet template (status `ready` so it is immediately claimable):

```markdown
### Work Packet: smoke-finding/<short-slug>

- id: `smoke-finding/<short-slug>`
- owner_host: linux            # or any / macos / windows
- capability_tags: [rust, podman, vault, testing, release]   # intersect what's needed
- status: ready
- discovered_by: `/smoke-curl-install-and-test-e2e` on release `<RELEASE_TAG>`
- evidence:
  - `target/smoke-e2e/03-init.log:<line>` — <one-line excerpt>
- repro:
  - smallest command that reproduces (e.g. `tillandsias --debug --init`)
- next_action: >
    <smallest concrete diagnostic or fix the next worker should attempt>
- events:
  - type: discovered
    ts: `<ISO-8601-UTC>`
    agent_id: `<your-agent-id>`
    host: linux
```

Rules for good findings:

- **One issue per packet.** Split compound failures.
- **Always include a repro and a log excerpt.** A finding with no evidence is
  noise; cite `target/smoke-e2e/*.log:<line>`.
- **Redact secrets.** Never paste tokens or unredacted push URLs into a packet.
- **De-duplicate.** Before filing, grep `plan/issues/` for an existing packet on
  the same symptom; if found, append an `events:` note instead of a new packet.
- **No silent passes.** If the smoke ran clean end-to-end, still write a one-line
  PASS entry to the report (release tag + "init clean, forge run clean") so the
  convergence record shows the release was exercised.

Commit the report (and any forge-pushed findings) to the appropriate host branch (`linux-next`, `osx-next`, or `windows-next`) and push. **DO NOT push directly to `main` or open PRs against `main`.** Update the host work-queue
ledger with a one-line outcome, exactly as `/advance-work-from-plan` §6
prescribes.

Before a successful exit, the PASS/finding report must be committed and pushed.
Do not leave a local-only release smoke result.

---

## Guardrails

- **Never** skip Step 2 on a Tillandsias smoke host because it wipes Podman.
  The wipe is the precondition that makes the test meaningful. The only
  supported opt-out is `TILLANDSIAS_DESTRUCTIVE_RESET_OK=0`, which must produce
  a pushed plan blocker.
- **Never** substitute a local `target/` build for the curl-installed binary —
  that defeats the purpose (testing the published artifact).
- **Never** push fixes from this skill. This skill only *installs, observes, and
  files*. Fixes are the job of `/advance-work-from-plan` workers claiming the
  packets you filed.
- **Never** paste secrets into logs or packets; redact tokens and auth URLs.
- **Never** push directly to `main` or create PRs to `main`. Always use the appropriate host branch (`linux-next`, `osx-next`, or `windows-next`).
- Findings are intake, not authority — durable conclusions still land in
  `openspec/specs/`, `methodology/`, or cheatsheets via the normal flow.

## How orchestrators steer this skill

The canonical file lives at `skills/smoke-curl-install-and-test-e2e/SKILL.md`;
each runtime accesses it via a symlink under its `skills/` directory. An
orchestrator can set `TILLANDSIAS_DESTRUCTIVE_RESET_OK=0` for a non-smoke host,
change the forge prompt in Step 4, or adjust the finding capability_tags
between iterations.
