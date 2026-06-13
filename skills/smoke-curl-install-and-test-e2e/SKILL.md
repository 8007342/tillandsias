---
name: smoke-curl-install-and-test-e2e
description: Clean-room end-to-end smoke test of a PUBLISHED release. Curl-installs the latest release binary from GitHub, does a full `podman system reset --force`, runs `tillandsias --debug --init` from a pristine state, and (if init is clean) launches `tillandsias . --opencode --prompt "Use the /forge-continuous-enhancement skill"`. Every issue observed — by this skill's agent during install/reset/init, or by the agents running inside the forge under /forge-continuous-enhancement — is filed as a plan/issues work packet for later pickup by /advance-work-from-plan.
---

# Smoke: Curl-Install and Test End-to-End

This skill validates that a **published release** actually works for a real
operator starting from nothing. It is the acceptance gate that catches what
`./build.sh --ci-full` cannot: problems that only appear when the signed,
downloadable binary bootstraps the whole enclave from a wiped Podman store on a
clean host.

## Authority

`methodology.yaml` remains the source of truth. This skill is an executable
runbook; it does not redefine release, trace, or coordination policy. Findings
become `plan/issues/` work packets so they flow through the normal
`/advance-work-from-plan` worker loop.

---

## ⚠️ DESTRUCTIVE — read before running

Step 2 runs **`podman system reset --force`**, which **irreversibly deletes ALL
Podman state for this user**: every container, image, volume, network, and
secret — including:

- the `tillandsias-vault-data` volume (Vault's sealed store),
- every project mirror volume (`tillandsias-mirror-*`),
- all locally built enclave images (proxy/git/inference/forge) — these get
  **rebuilt from scratch on the next `--init`, which can take many minutes**.

**Only run this on a host where wiping Podman is acceptable** (a dedicated
smoke/CI host, or with explicit operator go-ahead for "now"). Confirm timing
with the operator before Step 2 if you are on their primary workstation. Never
run it unattended on a machine doing other Podman work.

A fresh `--init` re-initializes Vault and re-captures the keychain-held unseal
share, so the keychain↔volume resync brick (see git history `738059bc`) is part
of what this smoke exercises — if init bricks, that is a finding, not a failure
to hide.

---

## 0 — Pre-flight

1. **Identify host + branch** (Linux → `linux-next`, macOS → `osx-next`,
   Windows → `windows-next`). This runbook targets a Linux runtime host; the
   `--opencode` forge lane is Linux/Podman today.
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

Install the published binary the canonical way an operator would — do NOT use a
locally built `target/` binary; the whole point is to test the *download*.

```bash
curl -fsSL https://github.com/8007342/tillandsias/releases/latest/download/install.sh | bash 2>&1 \
  | tee target/smoke-e2e/01-install.log
hash -r
tillandsias --version | tee target/smoke-e2e/01-version.txt
```

Verify the installed version matches the release tag from Step 0. If the install
script errors, the version mismatches, or `tillandsias` is not on `PATH`
afterward → **file a finding (capability: `release`, `install`) and STOP**;
the rest of the smoke is invalid on a bad install.

---

## 2 — Full Podman reset (DESTRUCTIVE — see warning above)

```bash
podman system reset --force 2>&1 | tee target/smoke-e2e/02-reset.log
```

Confirm afterward that the store is empty:
```bash
podman ps -a --format '{{.Names}}'; podman volume ls -q; podman images -q
```
All three should be empty. If the reset errors or leaves residue → file a
finding (capability: `podman`, `runtime`) and note it, then continue only if the
store is actually clean.

---

## 3 — Fresh init from a pristine state

```bash
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
tillandsias . --opencode --prompt "Use the /forge-continuous-enhancement skill" 2>&1 \
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

---

## Guardrails

- **Never** run Step 2 (`podman system reset --force`) on a host doing other
  Podman work without explicit "now" go-ahead. It is irreversible.
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
orchestrator can tighten the destructive-reset gate, change the forge prompt in
Step 4, or adjust the finding capability_tags between iterations.
