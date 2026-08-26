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
| Windows | `scripts/install-windows.ps1` release path when available | `wsl --unregister tillandsias`, cache purge, plus `vault-shamir-share-v1` + `vault-root-token-v1` cleared from Credential Manager (keeping `tillandsias-vm-uuid`) | installed tray provision/diagnose |

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
2. **Choose the channel and resolve the release under test.** Two channels
   (plan order 305 + operator directive 2026-07-15):
   - **`daily` (DEFAULT for routine smoke)** — the newest release *including
     prereleases* (the latest daily). Routine curl-install smoke tracks the
     bleeding edge because that is the next promotion candidate.
   - **`stable` (one-shot after a promotion)** — the newest non-prerelease
     (what `/releases/latest` and the README serve). Run this ONCE right
     after `scripts/promote-stable.sh` promotes a release, to prove the
     promoted artifact installs; then routine runs go back to `daily`.
   ```bash
   CHANNEL="${SMOKE_CHANNEL:-daily}"
   read -r RES < <(scripts/resolve-smoke-release.sh "$CHANNEL")
   echo "$RES"   # channel:<c> tag:<vX> base:<url>
   SMOKE_TAG="$(printf '%s' "$RES" | sed -E 's/.* tag:([^ ]+) .*/\1/')"
   # `[^ ]+`, NOT `\S`. `\S` is a GNU sed extension: BSD sed does not match it,
   # so on macOS this substitution silently fails and SMOKE_BASE becomes the
   # WHOLE line — `channel:daily tag:… base:https://…` — and every curl below
   # is built from a malformed URL. The TAG line directly above already uses the
   # portable form; the two were written at different times and only one lane
   # ever ran them. Caught by dry-running step 0 on macOS before the first real
   # macOS smoke, 2026-08-26.
   SMOKE_BASE="$(printf '%s' "$RES" | sed -E 's/.* base:([^ ]+)$/\1/')"
   ```
   Note the tag — every filed finding cites it so issues are attributable to a
   specific published artifact AND channel.
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

The installer honors `TILLANDSIAS_RELEASE_BASE` so the smoke pins the exact
resolved release (`$SMOKE_BASE`) instead of the hard-coded
`/releases/latest/download` (which is stable-only by GitHub semantics — it
would ignore the daily prerelease). Real users are unaffected: with the env
unset the installer defaults to the stable channel.

```bash
TILLANDSIAS_SMOKE_LOCK_LOG=target/smoke-e2e/00-smoke-lock.log \
  scripts/with-smoke-lock.sh --name release-smoke-e2e -- \
  bash -c "curl -fsSL '${SMOKE_BASE}/install.sh' | TILLANDSIAS_RELEASE_BASE='${SMOKE_BASE}' bash" 2>&1 \
  | tee target/smoke-e2e/01-install.log
INSTALL_RC=${PIPESTATUS[0]}; printf 'install_exit=%s\n' "$INSTALL_RC" | tee target/smoke-e2e/01-install-exit.txt
test "$INSTALL_RC" -eq 0
hash -r
tillandsias --version | tee target/smoke-e2e/01-version.txt
test "${PIPESTATUS[0]}" -eq 0
# The comment used to say "must equal $SMOKE_TAG". Now it is checked.
grep -qF "${SMOKE_TAG#v}" target/smoke-e2e/01-version.txt
```

> Three assertions replacing a pipe and a comment (order 727-kmks). The
> installer ran through `| tee`, so a curl-install that failed outright exited 0
> — `tee` wrote the failure into the evidence file and the smoke walked on. The
> version line then carried `# must equal $SMOKE_TAG` as a comment, which meant
> the clean-room test of a PUBLISHED release never once confirmed it was running
> the release it claimed to be testing: a stale binary already on PATH would
> answer `--version` and pass.

macOS:

```bash
curl -fsSL "${SMOKE_BASE}/install-macos.sh" | TILLANDSIAS_RELEASE_BASE="${SMOKE_BASE}" bash 2>&1 \
  | tee target/smoke-e2e/01-install-macos.log
INSTALL_RC=${PIPESTATUS[0]}; printf 'install_exit=%s\n' "$INSTALL_RC" \
  | tee target/smoke-e2e/01-install-macos-exit.txt
test "$INSTALL_RC" -eq 0

# install-macos.sh extracts to /Applications — but FALLS BACK to
# ~/Applications when /Applications is not writable, and this runbook then
# verifies /Applications unconditionally. Assert which branch it took rather
# than assuming: a stale ~/Applications copy plus a silent fallback is the
# live mixup of 2026-07-16, and it "verifies" the wrong binary.
test -d "/Applications/Tillandsias.app"
! grep -q "not writable; using" target/smoke-e2e/01-install-macos.log

"/Applications/Tillandsias.app/Contents/MacOS/tillandsias-tray" --version 2>&1 \
  | tee target/smoke-e2e/01-version.txt
test "${PIPESTATUS[0]}" -eq 0
# EXACT, not `>=` and not "contains 0.4". Assertable at all only since
# 635-bhkb: every macOS build answered `0.1.0` before it, so this lane could
# not confirm which release it was testing even in principle.
grep -qF "tillandsias-tray ${SMOKE_TAG#v} " target/smoke-e2e/01-version.txt
```

> The same three assertions the Linux lane got in 727-kmks, plus two the macOS
> lane needs and Linux does not. The install ran through `| tee` with no
> `PIPESTATUS` capture and the version check ended in `|| true` — so a
> curl-install that failed outright, and a `--version` that failed after it,
> both exited 0 and the smoke walked on. That is the identical defect 727-kmks
> fixed one lane over, left standing here, in the lane that had never once been
> run against a published release.
>
> The two extra assertions are the `/Applications`-vs-`~/Applications`
> fallback (the installer chooses, this runbook does not, and only one of them
> is the path verified below) and the exact-tag match, which was not expressible
> before 635-bhkb.

Windows PowerShell (daily-channel pinned — the release publishes
`install-windows.ps1` + the x64 tray zip since v0.3.260721.1; the installer
honors `TILLANDSIAS_VERSION` for an exact-tag pin, so the smoke installs the
SAME resolved daily as the Linux/macOS lanes instead of `/releases/latest`,
which is stable-only by GitHub semantics):

```powershell
# $SmokeTag from pre-flight, e.g. v0.3.260721.1 (strip/keep the leading v —
# the installer normalizes both).
$env:TILLANDSIAS_VERSION = $SmokeTag
irm "https://github.com/8007342/tillandsias/releases/download/$SmokeTag/install-windows.ps1" | iex `
  *>&1 | Tee-Object target\smoke-e2e\01-install-windows.log
Remove-Item Env:TILLANDSIAS_VERSION
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
RESET_RC=${PIPESTATUS[0]}; printf 'reset_exit=%s\n' "$RESET_RC" | tee target/smoke-e2e/02-reset-exit.txt
test "$RESET_RC" -eq 0
```

Confirm afterward that the store is empty:
```bash
CONTAINERS="$(podman ps -aq)"; VOLUMES="$(podman volume ls -q)"; IMAGES="$(podman images -q)"
printf '[containers]\n%s\n[volumes]\n%s\n[images]\n%s\n' "$CONTAINERS" "$VOLUMES" "$IMAGES" \
  | tee target/smoke-e2e/02-empty-store.txt
test -z "$CONTAINERS"; test -z "$VOLUMES"; test -z "$IMAGES"
```

If the reset errors or leaves residue → file a finding (capability: `podman`,
`runtime`).

> This step was prose until 727-kmks: the reset was piped to `tee` with no
> `PIPESTATUS` capture, so a failed reset exited 0, and "All three should be
> empty" was an instruction rather than an assertion. Its sibling runbook
> (`build-install-and-smoke-test-e2e` §2) already asserted both, which is what
> made the gap visible — the same destruction gate was executable on one path
> and advisory on the other, and this is the path that tests PUBLISHED releases.

On macOS, stop the tray, then destroy the VM substrate and ASSERT it is gone.

The paths are correct as written and match the source of truth
(`status_item.rs:367`, `diagnose.rs:71`, `scripts/uninstall.sh:19` — all
lowercase `tillandsias`). What was missing is the ASSERTION: this was one prose
sentence while the Linux branch above captures `PIPESTATUS` and then proves the
store is empty. That asymmetry is exactly what the 727-kmks note describes, one
layer down — and this is the path that tests PUBLISHED releases, so a removal
that silently matched nothing would let the smoke run against a pre-existing
multi-GiB VM image while reporting a clean-room result. A false PASS on the
destruction precondition is worse than a red run, because it gates promotion.

```bash
pkill -f 'Tillandsias.app/Contents/MacOS/tillandsias-tray' 2>/dev/null || true
rm -rf "$HOME/Library/Application Support/tillandsias" \
       "$HOME/Library/Caches/tillandsias"
# ASSERT, do not assume — the point of this block.
MACOS_RESIDUE=""
for d in "$HOME/Library/Application Support/tillandsias" \
         "$HOME/Library/Caches/tillandsias"; do
    [ -e "$d" ] && MACOS_RESIDUE="${MACOS_RESIDUE}${d}"$'\n'
done
printf '[macos-residue]\n%s' "$MACOS_RESIDUE" | tee target/smoke-e2e/02-macos-residue.txt
test -z "$MACOS_RESIDUE"
```

If residue survives → file a finding (capability: `macos`, `runtime`) and do NOT
continue.

> A NOTE ON WHAT DID NOT NEED FIXING, so nobody re-opens it (889-bx99,
> retracted). This step was reported as carrying a case bug — capital-`T`
> `Tillandsias` on disk versus lowercase in the runbook. It does not. The
> reporting host checked by typing a capital-`T` path and watching it resolve,
> on a case-INSENSITIVE volume where any spelling resolves; `ls` of the PARENT
> shows the stored name is lowercase, matching the code. When testing a
> case-sensitivity hypothesis, read the stored name — a path you typed yourself
> proves only that the filesystem folded it.

On Windows, stop the tray, then run `wsl --terminate tillandsias` followed by
`wsl --unregister tillandsias`, tolerating an already-absent distro.

**Then clear the host credential store, or the run is not a clean room (order
804-ckst).** Unregistering the distro and purging the cache leave Windows
Credential Manager untouched, and the tray treats it as authoritative:

```powershell
# 'tillandsias-vm-uuid' is deliberately PRESERVED -- it anchors the
# INSTALLATION, not the guest, and the in-VM Vault derives its master key
# from it. Only the two guest-vault entries go.
foreach ($cred in @('vault-shamir-share-v1', 'vault-root-token-v1')) {
    $listed = & cmdkey.exe /list:$cred 2>$null
    if ($listed -match [regex]::Escape($cred)) { & cmdkey.exe /delete:$cred > $null 2>&1 }
}
$stillThere = @('vault-shamir-share-v1', 'vault-root-token-v1') | Where-Object {
    (& cmdkey.exe /list:$_ 2>$null) -match [regex]::Escape($_)
}
if ($stillThere) { throw "host vault credentials survived the reset: $($stillThere -join ', ')" }
```

This is not hygiene, it is the difference between a valid result and an
invalid one. The 2026-08-17 run on v0.4.260817.1 claimed a "truly cold" run
because it purged the 34.9 GB `ext4.vhdx` AND the rootfs cache — both true,
both irrelevant to this store. The stale share survived, the tray delivered it
into the fresh guest unconditionally, and the release looked healthy in the
smoke and then broke for the operator forty minutes later on the first GitHub
login (803-49re). A "cold" claim without this step is a claim the run cannot
support.

**Use `--terminate`, NOT `wsl --shutdown` (order 802-bajv).** `--shutdown` stops
EVERY WSL2 distro on the host, while `--unregister` only requires the target
distro to be stopped. A Windows host commonly also runs `tillandsias-build` —
the lane that builds Linux-target artifacts, kept deliberately separate so the
smoke cannot wipe a toolchain mid-cycle — and a global shutdown kills it for no
test benefit.

**This step DESTROYS the model cache, and that is not a footnote (order
806-a4tu).** On Windows the weights live at `/root/.cache/tillandsias/models`
INSIDE the distro's `ext4.vhdx`, so `--unregister` deletes them along with the
disk. Measured on yolanda 2026-08-17: ~447 MB of `nomic-embed-text` plus
`qwen2.5:0.5b` had to be re-pulled after the reset. Every Windows run of this
smoke therefore starts cold BY CONSTRUCTION. Do not describe a Windows result as
a warm-cache run, and do not treat warm-vs-cold as a variable on this lane — it
has exactly one value. Budget the re-pull into the run, and note that a host on a
metered or slow link pays it every time.

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
