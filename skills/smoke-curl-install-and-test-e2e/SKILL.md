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
| macOS | `scripts/install-macos.sh` via release curl URL — **launches the tray and begins VM provisioning; not a download test (1281-pgit)** | remove Tillandsias app state/cache VM dirs | installed tray `--provision` + `--diagnose --json` |
| Windows | `scripts/install-windows.ps1` release path when available | `wsl --unregister tillandsias`, cache purge, plus `vault-shamir-share-v1` + `vault-root-token-v1` cleared from Credential Manager (keeping `tillandsias-vm-uuid`) | installed tray provision/diagnose — implemented by the §3 "Windows" block (`--provision-once`, `--status-once --json` polled to Ready, `--diagnose --json` LAST) |

This is the only e2e install skill allowed on immutable Linux.

## DESTRUCTIVE — read before running

On Linux, Step 2 runs **`podman system reset --force`**, which irreversibly
deletes ALL Podman state for this user: every container, image, volume, network,
and secret — including:

- the `tillandsias-vault-data` volume (Vault's sealed store),
- every project mirror volume (`tillandsias-mirror-*`),
- all locally built enclave images (proxy/git/inference/forge) — these get
  **rebuilt from scratch on the next `--init`, which can take many minutes**.

On a DEDICATED SMOKE HOST, wiping Podman is expected and is a required
precondition for the release idempotence test. If
`TILLANDSIAS_DESTRUCTIVE_RESET_OK` is unset or `1`, do not ask for confirmation,
do not pause for operator timing, and do not skip Step 2 because Podman state
will be destroyed. Only block the reset when the environment explicitly sets
`TILLANDSIAS_DESTRUCTIVE_RESET_OK=0`, in which case file a plan blocker and
push it.

**That no-pause clause applies to a dedicated smoke host and to nothing else
(order 1004-vsh2, 2026-09-04).** On an OPERATOR'S WORKSTATION — a machine whose
guest holds work they have not finished with — Step 2 destroys their Vault
store, their project mirrors and their images, and this document cannot consent
on their behalf. Get the operator's authorization for THAT RUN before starting.
An orchestrator's or a peer agent's instruction to run this skill is not that
authorization: it is a request to run a procedure, not consent to destroy a
particular machine's state. The distinction was missed once because this
section read as though every host running it were a smoke host; most of the
fleet's Windows and macOS hosts are workstations.

**`TILLANDSIAS_RESET_KEEP_MODELS=1`** lets this destruction spare the model
cache (`cache_root()/models`) on the operator's word — opt-in, per run, never
the default: the clean room stays clean unless this run asked otherwise (the
2026-09-13 reset ruling; operator, 2026-09-14: "let's add the keep models
flag to our resets"). Per platform: **Linux** — the podman reset and the
credential clearer never touch `~/.cache/tillandsias/models`, so the flag is
a documented no-op and the models survive regardless. **macOS** — honoured by
`scripts/e2e-step2-macos.sh` below, which names the spared directory in its
residue line. **Windows** — a no-op until 1182-2vaz moves the weights out of
the distro (they live at `/root/.cache/tillandsias/models` inside the vhdx
that `wsl --unregister` deletes) (operator ruling 2026-09-14; 1181-bkem).

A fresh `--init` re-initializes Vault and re-captures the keychain-held unseal
share, so the keychain↔volume resync brick (see git history `738059bc`) is part
of what this smoke exercises — if init bricks, that is a finding, not a failure
to hide.

**On Linux this is true only because the reset now CLEARS the host-held
credentials (order 900-z3kv). Step 2 runs
`scripts/clear-vault-host-credentials.sh` after emptying the store; without it
the paragraph above was false.** `podman system reset --force` empties the podman
store — containers, volumes AND images — but it does not reach the HOST
KEYCHAIN. Vault then recovers the pre-existing Shamir share and logs `preserving
existing data volume (Shamir share present in keychain)`, so without the clearer the resync path
above is **not exercised** — which is what every Linux pass silently carried
until 900-z3kv wired it. Measured independently on two Linux hosts with
differently-aged shares (yoga, created 2026-06-15; lenovinha, created
2026-07-08), which makes it a property of the Linux lane rather than one host's
dirty state — and it means every Linux "clean room" pass since at least 2026-06
silently carried this gap.

Run `scripts/probe-credential-cold-state.sh --format=md` and paste its block
into the findings file, the way the Windows leg records its hashes. It reports
`credential-cold` or `credential-warm` from **metadata only** — never
`secret-tool search --all`, which prints the secret inline and put live tokens
into two transcripts on 2026-08-25 — and reports `could-not-run` when the
question cannot be asked, which must never be read as cold.

**Since 1149-vgn2 it checks the host keychain AND
`~/.cache/tillandsias/fallback_*`, and a cold verdict names everything it
checked.** It read the keychain alone until then, so pirria — no keychain
item, a `fallback_vault-shamir-share-v1` untouched since 2026-09-01 keeping
every reset warm — was certified cold, and the verdict's own text claimed the
resync path was exercised. If the checkout running this skill predates
1149-vgn2, its cold verdict is keychain-only: do not trust it (drill: plan/issues/fleet-restart-2026-09-12.md, 1149-vgn2 fixed: the cold probe now checks the fallback share).

**DECIDED (900-z3kv, operator ruling 2026-09-13): the reset clears the
host-held credentials.** Not open — the platform prefers idempotency to
legacy support, and `podman system reset --force` is the baseline.
`scripts/clear-vault-host-credentials.sh` clears THREE locations: the
keychain items `vault-shamir-share-v1` and `vault-root-token-v1`, the
`~/.cache/tillandsias/fallback_*` copies of both, and
`~/.cache/tillandsias/vault-data`. `installation-uuid-v1` is deliberately
PRESERVED — it anchors the INSTALLATION, and clearing it makes the next vault
underivable rather than re-initialized. **Read the clearer's own last line,
not the reset's exit code:** a partial clear prints
`warn:clear-vault-credentials:partial` and still exits 0, which is precisely
the state that looks cold and is not (drill: plan/issues/fleet-restart-2026-09-12.md, 900-z3kv COMPLETED).

---

On macOS, the destructive substrate is the Tillandsias Virtualization.framework
state and cache directories. On Windows, it is the `tillandsias` WSL2 distro and
download cache.

## 0 — Pre-flight

0. **Shell: every fenced `bash` block in this runbook runs under bash, and the
   first line of each block asserts it.** `PIPESTATUS` is a bash array; under
   zsh it expands EMPTY and zsh's `test "" -eq 0` is TRUE, so every exit-code
   assertion below silently passes on a failed step (measured on pirria,
   2026-09-04: the first install attempt recorded `install_exit=` and walked
   on — the exact walk-past-a-failed-install 727-kmks wrote the assertions to
   kill, reintroduced by shell choice; order 1004-fue3). Paste this line at the
   top of every bash block, or run each block as `bash -c '...'`:
   ```bash
[ -n "${BASH_VERSION:-}" ] || { echo 'FAIL: run this block under bash — PIPESTATUS is a bash array and zsh expands it empty'; exit 2; }
   [ -n "${BASH_VERSION:-}" ] || { echo 'FAIL: run this block under bash — PIPESTATUS is a bash array and zsh expands it empty'; exit 2; }
   ```
   Every assertion on a captured status also checks the capture is NON-EMPTY
   (`test -n "$RC" && test "$RC" -eq 0`), so a void capture fails loud even if
   the guard above is skipped. PowerShell blocks assert `$LASTEXITCODE` and
   `$?` instead; there is no PIPESTATUS there.

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
   awk -v tag="${SMOKE_TAG}" '
       # 1. An exact row for this tag.
       $0 ~ "^\\| " tag "( |\\()" { print; found=1; next }
       # 2. A DISTILLED SPAN covering it (order 380). Old series are collapsed
       #    into one `first … last` row, so a tag inside that range HAS been
       #    described — just not individually. Without this arm a distilled tag
       #    is indistinguishable from an undescribed one, and the finding below
       #    fires falsely on every release old enough to have been compressed.
       /^\| v[0-9].* … v[0-9].*DISTILLED/ {
           split($0, c, "|"); split(c[2], span, "…")
           lo = span[1]; hi = span[2]
           gsub(/[^0-9A-Za-z.]/, "", lo); gsub(/ .*/, "", hi); gsub(/[^0-9A-Za-z.]/, "", hi)
           if (tag >= lo && tag <= hi) { print; found=1; distilled=1 }
       }
       END {
           if (!found) print "NO LEDGER ROW for " tag
           else if (distilled) print "(row is a DISTILLED span, not a per-release row — claims are series-level)"
       }
   ' README.md | tee target/smoke-e2e/00-ledger-row.txt
   ```
   Note the tag — every filed finding cites it so issues are attributable to a
   specific published artifact AND channel.
2b. **Read the release's own ledger row BEFORE testing it** (order 380).
   `README.md` carries a RELEASE / INTENDED FEATURES / BUGFIXES table, and the
   row for `$SMOKE_TAG` is the release stating **what it claims to have fixed**:

   ```bash
   awk -v tag="${SMOKE_TAG}" '
       # 1. An exact row for this tag.
       $0 ~ "^\\| " tag "( |\\()" { print; found=1; next }
       # 2. A DISTILLED SPAN covering it (order 380). Old series are collapsed
       #    into one `first … last` row, so a tag inside that range HAS been
       #    described — just not individually. Without this arm a distilled tag
       #    is indistinguishable from an undescribed one, and the finding below
       #    fires falsely on every release old enough to have been compressed.
       /^\| v[0-9].*DISTILLED/ {
           row = $0
           sub(/^\| /, "", row); split(row, parts, " … ")
           lo = parts[1]; hi = parts[2]; sub(/ .*$/, "", hi)
           if (tag >= lo && tag <= hi) { print; found=1; distilled=1 }
       }
       END {
           if (!found) print "NO LEDGER ROW for " tag
           else if (distilled) print "(DISTILLED span — claims are series-level, not per-release)"
       }
   ' README.md | tee target/smoke-e2e/00-ledger-row.txt
   ```

   **Why this is a step and not a courtesy.** Without it the smoke validates a
   generic property — it installs, it destroys, it re-provisions — against
   *any* release, and cannot tell whether the specific thing this release says
   it repaired actually got repaired. The row names orders; those are checkable.
   On 2026-08-26 the macOS lane verified that `--version` reports the workspace
   VERSION rather than `0.1.0`, which is precisely what that row claims for
   635-bhkb — **but by coincidence, because the runbook had just been changed,
   not because anything directed the run at the claim.**

   Cite the row in the §5 report and state which of its claims this lane
   exercised, which it could not, and which it did not look at. A claim the
   lane cannot reach (a Windows fix on the macOS lane) is a legitimate
   *not-applicable*; a claim it could have checked and did not is a gap in the
   run, and only naming them separately makes that visible.

   **A MISSING ROW IS A FINDING, NOT A SKIP.** `NO LEDGER ROW for <tag>` means
   either the release skill's append step did not run for this release, or the
   smoke is testing an artifact nobody described. Both are worth a packet, and
   both are invisible if this step silently proceeds.
3. **Record sibling heads** (`main`, `linux-next`, `windows-next`, `osx-next`)
   per multi-host discipline.
4. **ARCHIVE THE PREVIOUS RUN'S EVIDENCE, THEN create the findings log dir**
   (order 1189-7yvu). `mkdir -p` on its own is what let a run inherit every
   file from every previous run:
   ```bash
   SMOKE_EVIDENCE_DIR=target/smoke-e2e
   SMOKE_RUN_START="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
   # MOVE ASIDE, NEVER DELETE — prior evidence is worth keeping, and a step
   # that deletes it makes the previous run unreconstructable.
   if [ -d "$SMOKE_EVIDENCE_DIR" ] && [ -n "$(ls -A "$SMOKE_EVIDENCE_DIR" 2>/dev/null)" ]; then
       SMOKE_ARCHIVE="$SMOKE_EVIDENCE_DIR/_archived-$(date -u +%Y%m%dt%H%M%Sz)"
       mkdir -p "$SMOKE_ARCHIVE"
       # Move every entry except the archive dirs themselves.
       for _e in "$SMOKE_EVIDENCE_DIR"/*; do
           case "$_e" in *"/_archived-"*) continue ;; esac
           [ -e "$_e" ] && mv "$_e" "$SMOKE_ARCHIVE"/
       done
       printf 'archived_to=%s\n' "$SMOKE_ARCHIVE"
   fi
   mkdir -p "$SMOKE_EVIDENCE_DIR"
   printf 'run_start=%s\n' "$SMOKE_RUN_START" | tee "$SMOKE_EVIDENCE_DIR/00-run-start.txt"
   ```
   **WHY THIS IS NOT HOUSEKEEPING.** In-block assertions capture their status
   in the same shell and are unaffected. Every OUT-OF-BAND read is affected:
   the §5 report, an orchestrator polling for completion, a human scanning the
   directory. A step that never reaches its write leaves the PREVIOUS run's
   file under the exact name those readers open, so a stale PASS is
   indistinguishable from a fresh one BY NAME.

   MEASURED on pirria 2026-09-14: `03-init-exit.txt` containing `init_exit=0`,
   dated 2026-09-13 01:24, was present and being read as this run's result
   while this run's `--init` was still building the proxy image. Fourteen files
   from the 2026-09-12/13 runs were present at start and had to be archived by
   hand.

   **CHECK EVIDENCE AGAINST `run_start`, not against its existence.** Any file
   in the directory older than `00-run-start.txt` is a leak from an incomplete
   archive, not a result:
   ```bash
   find "$SMOKE_EVIDENCE_DIR" -maxdepth 1 -type f \
        ! -newer "$SMOKE_EVIDENCE_DIR/00-run-start.txt" \
        ! -name 00-run-start.txt -print
   # any output here is stale evidence that survived the archive step
   ```
5. **Source the timing helpers, and keep them sourced for every block below**
   (order 1013-qv7c). Each smoke step emits ONE duration record so the
   recurrence rung (`repeat:` / `recur:` / `skippable:` in
   `scripts/cycle-metrics.sh`) can see this runbook's work:
   ```bash
   . "$PWD/scripts/timing-log.sh" 2>/dev/null || true
   command -v timing_emit >/dev/null 2>&1 || { timing_now_ms() { echo 0; }; timing_emit() { return 0; }; }
   command -v timing_begin >/dev/null 2>&1 || { timing_begin() { return 0; }; timing_commit() { return 0; }; timing_reap() { return 0; }; }
   timing_reap
   ```
   `timing_reap` reports on the PREVIOUS run, not this one (order 1026-ps4n).
   If a earlier smoke's supervising shell was killed mid-step, its start stamp
   is still on disk; reaping turns it into a `<step>-supervisor-lost` record so
   the log says what happened instead of being silent. Run it first, before any
   step below writes a stamp of its own.
   **Why this and not the gate.** Every other emitter in the tree is a
   build/test/litmus step in `build.sh`, `scripts/local-ci.sh` or
   `scripts/run-litmus-test.sh`, and all of those need cargo. A floor host
   without a toolchain therefore has *never* written a timing record —
   measured on pirria 2026-09-04, where `repeat:`/`recur:`/`skippable:` all
   read `source=absent` and `.cache/metrics/` was an empty directory the probe
   itself created. An instrument for finding what slow hosts pay cannot be
   downstream of the thing slow hosts cannot run. `timing_emit` is bash and
   `jq`, needs no toolchain, and the smoke is work the floor *can* do — so the
   records come from here.

   The emits are **best-effort by construction**: `timing_emit` wraps its whole
   body and always returns 0, and the fallback stub above keeps every call site
   unconditional and `set -e`-safe. A metrics write can never fail a smoke step.

   Records are named `phase=smoke` with these pinned `step` values, one per
   step below: `smoke-curl-install`, `smoke-destructive-reset`,
   `smoke-init-pristine`, `smoke-forge-lane`, `smoke-health-check`. They land
   in `<checkout>/.cache/metrics/tillandsias-timing.jsonl` (the same log the
   gate steps write) and are read back by `scripts/cycle-metrics.sh`.

   A sixth name appears only when something went wrong:
   `smoke-forge-lane-supervisor-lost` (order 1026-ps4n). It means a previous
   run's shell was killed while the lane was running, and its `duration_ms` is
   a **lower bound** — the end was never observed. It is deliberately a
   separate step name so it can never be averaged into `smoke-forge-lane`;
   see §4a for what that state looks like on the host and why it is not a
   product failure.

---

## 1 — Curl-install the latest release

Install the published artifact the canonical way an operator would — do NOT use a
locally built `target/` binary; the whole point is to test the *download*.

**`install.sh` is not a download test — it runs the full init (1133-kktm).**
Measured on v56.9.12.2: 131 lines of podman/vault output, a Vault bootstrap
provisioning twelve policies and AppRole roles, and a `tillandsias-vault`
container left running on 8201. Reversible, not inert, and not what
"curl-install and assert the tag" describes above. The §1/§2 consent line
still holds (§2 destroys, §1 provisions), but on an operator's workstation say
what §1 actually does before running it; consent to a download check is not
consent to a Vault bootstrap (drill: plan/issues/fleet-restart-2026-09-12.md, §1 of the smoke is not a non-destructive binary install).

Linux:

The installer honors `TILLANDSIAS_RELEASE_BASE` so the smoke pins the exact
resolved release (`$SMOKE_BASE`) instead of the hard-coded
`/releases/latest/download` (which is stable-only by GitHub semantics — it
would ignore the daily prerelease). Real users are unaffected: with the env
unset the installer defaults to the stable channel.

```bash
[ -n "${BASH_VERSION:-}" ] || { echo 'FAIL: run this block under bash — PIPESTATUS is a bash array and zsh expands it empty'; exit 2; }
_T0="$(timing_now_ms)"
TILLANDSIAS_SMOKE_LOCK_LOG=target/smoke-e2e/00-smoke-lock.log \
  scripts/with-smoke-lock.sh --name release-smoke-e2e -- \
  bash -c "curl -fsSL '${SMOKE_BASE}/install.sh' | TILLANDSIAS_RELEASE_BASE='${SMOKE_BASE}' bash" 2>&1 \
  | tee target/smoke-e2e/01-install.log
INSTALL_RC=${PIPESTATUS[0]}; printf 'install_exit=%s\n' "$INSTALL_RC" | tee target/smoke-e2e/01-install-exit.txt
timing_emit smoke-curl-install smoke "$_T0" "${INSTALL_RC:-1}" || true
test -n "$INSTALL_RC" && test "$INSTALL_RC" -eq 0
hash -r
tillandsias --version | tee target/smoke-e2e/01-version.txt
_rc=${PIPESTATUS[0]}; test -n "$_rc" && test "$_rc" -eq 0
# The comment used to say "must equal $SMOKE_TAG". Now it is checked.
# BOUNDED (amendment to 1133-kktm): the version scheme is a monotonic
# counter, so an unbounded substring test would accept 56.9.12.20 as a match
# for 56.9.12.2. (drill: plan/issues/fleet-restart-2026-09-12.md, The promotion proven on the default Windows path)
grep -qE "(^|[^0-9.])${SMOKE_TAG#v}([^0-9.]|\$)" target/smoke-e2e/01-version.txt
```

> Three assertions replacing a pipe and a comment (order 727-kmks). The
> installer ran through `| tee`, so a curl-install that failed outright exited 0
> — `tee` wrote the failure into the evidence file and the smoke walked on. The
> version line then carried `# must equal $SMOKE_TAG` as a comment, which meant
> the clean-room test of a PUBLISHED release never once confirmed it was running
> the release it claimed to be testing: a stale binary already on PATH would
> answer `--version` and pass.

**`install-macos.sh` is not a download test either — it launches the tray and
provisions a VM (1281-pgit).** The hazard above is written for `install.sh` and
Linux; the macOS installer does the platform equivalent and had no equivalent
warning. MEASURED on macneo during the v56.9.19.1 and v56.9.19.2 smokes: §1 ends
with "Launching Tillandsias (--init / VM provisioning runs automatically on
first launch)", leaves a `tillandsias-tray` process running that §2 must then
stop, and provisioning downloads a ~528 MB Fedora Cloud image in the background.

WHY THE ASYMMETRY MATTERED, and why it is now stated on both paths: most of the
fleet's macOS hosts are OPERATORS' WORKSTATIONS rather than dedicated smoke
hosts, and this runbook has already recorded once that the distinction was
missed (1004-vsh2 — "this section read as though every host running it were a
smoke host"). A reader who has internalised "§1 is the safe download step, §2 is
the destructive one" is correct on Linux by documentation and wrong on macOS.
Say what §1 actually does before running it on a machine whose guest holds work
someone has not finished with.

AND AN INTERRUPTED INSTALL USED TO COST THE EXISTING APP. Until 1281-pgit the
installer removed the previous backup and moved the live app aside BEFORE
extracting, so a kill between those steps left `/Applications` with neither the
app nor a backup — measured here when the installer was piped through `head` to
read its first lines and died on SIGPIPE. The swap is now staged-extract,
rename, rename, with the old backup dropped last and a trap that restores it, so
the destination always holds a runnable app; `litmus:installer-swap-atomicity`
pins that. A SIGKILL is still untrappable, so do not pipe the installer into
something that closes early just to read its output — run it and read the log.

macOS:

```bash
[ -n "${BASH_VERSION:-}" ] || { echo 'FAIL: run this block under bash — PIPESTATUS is a bash array and zsh expands it empty'; exit 2; }
curl -fsSL "${SMOKE_BASE}/install-macos.sh" | TILLANDSIAS_RELEASE_BASE="${SMOKE_BASE}" bash 2>&1 \
  | tee target/smoke-e2e/01-install-macos.log
INSTALL_RC=${PIPESTATUS[0]}; printf 'install_exit=%s\n' "$INSTALL_RC" \
  | tee target/smoke-e2e/01-install-macos-exit.txt
test -n "$INSTALL_RC" && test "$INSTALL_RC" -eq 0

# install-macos.sh extracts to /Applications — but FALLS BACK to
# ~/Applications when /Applications is not writable, and this runbook then
# verifies /Applications unconditionally. Assert which branch it took rather
# than assuming: a stale ~/Applications copy plus a silent fallback is the
# live mixup of 2026-07-16, and it "verifies" the wrong binary.
test -d "/Applications/Tillandsias.app"
! grep -q "not writable; using" target/smoke-e2e/01-install-macos.log

"/Applications/Tillandsias.app/Contents/MacOS/tillandsias-tray" --version 2>&1 \
  | tee target/smoke-e2e/01-version.txt
_rc=${PIPESTATUS[0]}; test -n "$_rc" && test "$_rc" -eq 0
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
$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force target\smoke-e2e | Out-Null
$env:TILLANDSIAS_VERSION = $SmokeTag
$installExit = 0
try {
  $script = irm "https://github.com/8007342/tillandsias/releases/download/$SmokeTag/install-windows.ps1"
  Invoke-Expression $script *>&1 | Tee-Object target\smoke-e2e\01-install-windows.log
  if ($LASTEXITCODE) { $installExit = $LASTEXITCODE }
} catch {
  $_ | Out-String | Tee-Object -Append target\smoke-e2e\01-install-windows.log
  $installExit = 1
}
Remove-Item Env:TILLANDSIAS_VERSION
"install_exit=$installExit" | Tee-Object target\smoke-e2e\01-install-exit.txt
if ($installExit -ne 0) { throw "install failed (exit $installExit) — file a finding and STOP" }
# The tray is the only installed surface on Windows; assert it resolves NOW,
# not at §3 where a missing binary would read as a provision failure.
#
# MEASURED 2026-09-04 on yolanda (order 1004-vsh2): the installer does NOT put
# its directory on PATH, so a bare `Get-Command tillandsias-tray.exe` THROWS on
# a host where the install just succeeded — "not recognized as a name of a
# cmdlet". The binary is at $env:LOCALAPPDATA\Programs\Tillandsias, which the
# installer prints as its install path. Resolve PATH first (an operator may
# have added it) and fall back to the install location; only then fail.
$tray = (Get-Command tillandsias-tray.exe -ErrorAction SilentlyContinue |
    Select-Object -First 1 -ExpandProperty Source)
if (-not $tray) { $tray = "$env:LOCALAPPDATA\Programs\Tillandsias\tillandsias-tray.exe" }
if (-not (Test-Path $tray)) { throw "tray not found on PATH or at $tray after a successful install" }
"tray=$tray" | Tee-Object target\smoke-e2e\01-tray-path.txt
# EXACT, not "contains": the tray answers --version / -V (windows-tray
# main.rs), so the lane can confirm which release it is testing.
& $tray --version 2>&1 | Tee-Object target\smoke-e2e\01-version.txt | Out-Null
if ($LASTEXITCODE -ne 0) { throw "tray --version failed (exit $LASTEXITCODE)" }
$installedVersion = (Get-Content target\smoke-e2e\01-version.txt -Raw).Trim()
# BOUNDED (amendment to 1133-kktm): an unbounded substring match would accept
# 56.9.12.20 as a match for 56.9.12.2 — the version scheme is a monotonic
# counter, so the collision is reachable, not hypothetical.
if ($installedVersion -notmatch ('(?<![0-9.])' + [regex]::Escape($SmokeTag.TrimStart('v')) + '(?![0-9.])')) {
  throw "installed tray version '$installedVersion' does not carry release $SmokeTag"
}
```

> Same three assertions the Linux lane got on 727-kmks and macOS on
> 2026-08-26, added 2026-09-04 (order 1004-fue3): the old block piped `iex`
> into `Tee-Object` and asserted nothing, so a failed installer exited 0 and
> the smoke walked on — the shape the Linux lane had already been fixed for.
> The release-tag pin on this lane is the installer's `TILLANDSIAS_VERSION`
> (an exact tag: a tag that does not exist fails the download and trips the
> exit assertion). The tray's OWN version is asserted above from `--version` (the flag
> exists in windows-tray main.rs); the `.version` field of `--diagnose --json`
> is a second surface, asserted in §3 only when the build reports it.

Verify the installed version matches the release tag from Step 0. If the install
script errors, the version mismatches, or `tillandsias` is not on `PATH`
afterward → **file a finding (capability: `release`, `install`) and STOP**;
the rest of the smoke is invalid on a bad install.

### 1s — Verify the SIGNATURE of the artifact this lane installed (1273-4mak)

Until this section existed the smoke verified INTEGRITY and never AUTHENTICITY.
`install.sh` checks the asset's SHA256 against a `SHA256SUMS` fetched from the
same place as the asset, which is self-consistent by construction: a substituted
asset served with a regenerated manifest passes. The `.cosign.bundle` beside
every asset is the only artifact in the set that answers *who produced this*,
and nothing read one — on any lane, for any release, ever. It was declared
"NOT CHECKED" in the 08-28 Linux and Windows reports and in the 09-19 macOS
report, three platforms, three times, and stayed open: a gap everyone declares
and nobody closes is a missing GATE, not a missing observation.

**Two facts measured on v56.9.19.2 that decide the shape of these blocks:**

- **Every asset has its own `<asset>.cosign.bundle`** (32 assets). That is what
  these blocks verify.
- **`SHA256SUMS` and `SHA256SUMS-macos` have NO bundle; only
  `SHA256SUMS-windows` does.** So "verify the manifest and trust it for every
  asset it lists" is not available on the Linux or macOS lanes. Verify the
  ARTIFACT THIS LANE INSTALLED, against its own bundle.

**The precondition is probed, never inferred from an exit code.** The release's
`verify.sh` exits 1 both when cosign is MISSING and when a signature is BAD, and
those need opposite responses — one is "this run cannot answer the question",
the other is "this artifact is not what it claims". A block that reads rc=1 and
reports a failure turns a floor host without cosign into a fake security
incident; one that swallows rc=1 turns a bad signature into a pass. So each
block asks `command -v cosign` FIRST.

**`cosign:could-not-run:<reason>` IS NOT A PASS.** It is not a failure either —
`command -v cosign` returns nothing on macneo and on yoga today, and a host
without the tool has not found a bad signature, it has found nothing. It is a
THIRD verdict, and §5 requires it in the report's opening lines so a run that
could not verify cannot be filed as an unqualified PASS. That requirement is the
part that closes this gap rather than re-declaring it.

Linux — use the release's own `verify.sh`, which ships with every release:

```bash
cd "$(mktemp -d)" || exit 1
ASSET=tillandsias-linux-x86_64        # what install.sh actually downloads
if ! command -v cosign >/dev/null 2>&1; then
  echo "cosign:could-not-run:cosign-absent"
else
  curl -fsSL -O "$SMOKE_BASE/verify.sh" \
    && curl -fsSL -O "$SMOKE_BASE/$ASSET" \
    && curl -fsSL -O "$SMOKE_BASE/$ASSET.cosign.bundle" || {
         echo "cosign:could-not-run:asset-or-bundle-download-failed"; }
  if [ -f "$ASSET.cosign.bundle" ]; then
    if bash verify.sh "$ASSET"; then echo "cosign:verified:1/1"
    else echo "cosign:FAILED:$ASSET"; fi
  fi
fi
```

macOS — its own call, NOT an inherited Linux assumption. The lane verifies the
**tar.gz the installer consumed**, not a binary it never touched:

```bash
cd "$(mktemp -d)" || exit 1
ASSET="tillandsias-tray-${SMOKE_VERSION}-macos-arm64.tar.gz"
if ! command -v cosign >/dev/null 2>&1; then
  echo "cosign:could-not-run:cosign-absent (brew install cosign)"
else
  curl -fsSL -O "$SMOKE_BASE/verify.sh" \
    && curl -fsSL -O "$SMOKE_BASE/$ASSET" \
    && curl -fsSL -O "$SMOKE_BASE/$ASSET.cosign.bundle" || {
         echo "cosign:could-not-run:asset-or-bundle-download-failed"; }
  if [ -f "$ASSET.cosign.bundle" ]; then
    if bash verify.sh "$ASSET"; then echo "cosign:verified:1/1"
    else echo "cosign:FAILED:$ASSET"; fi
  fi
fi
```

`verify.sh` is bash and runs under macOS's bash 3.2, which is why this lane may
call it — but it is called HERE, on this lane's own artifact, so a future change
to the Linux block cannot silently redefine what macOS verified.

Windows PowerShell — `verify.sh` is bash, so this lane calls cosign directly:

```powershell
$asset = "tillandsias-windows-x64.zip"
if (-not (Get-Command cosign -ErrorAction SilentlyContinue)) {
  "cosign:could-not-run:cosign-absent (winget install sigstore.cosign)"
} else {
  $tmp = New-Item -ItemType Directory -Path (Join-Path $env:TEMP ([guid]::NewGuid()))
  Set-Location $tmp
  curl.exe -fsSL -O "$env:SMOKE_BASE/$asset"
  curl.exe -fsSL -O "$env:SMOKE_BASE/$asset.cosign.bundle"
  if (Test-Path "$asset.cosign.bundle") {
    cosign verify-blob --bundle "$asset.cosign.bundle" `
      --certificate-identity-regexp 'https://github\.com/8007342/tillandsias/' `
      --certificate-oidc-issuer 'https://token.actions.githubusercontent.com' `
      $asset
    if ($LASTEXITCODE -eq 0) { "cosign:verified:1/1" } else { "cosign:FAILED:$asset" }
  } else { "cosign:could-not-run:bundle-download-failed" }
}
```

**A `cosign:FAILED:` line is a STOP.** File a finding (capability: `release`,
`security`) and do not continue: an artifact whose signature does not verify
must not be exercised further, and the rest of the smoke would be reporting on
software of unknown origin. This is the one check whose failure is not a bug
report about Tillandsias but a question about what was downloaded.

Carry whichever `cosign:` line this lane emitted into §5 verbatim.


---

## 2 — Full substrate reset (DESTRUCTIVE — see warning above)

If `TILLANDSIAS_DESTRUCTIVE_RESET_OK=0`, stop here, write a plan blocker, and
push it. Otherwise run the reset immediately; on Linux this step is mandatory.

```bash
[ -n "${BASH_VERSION:-}" ] || { echo 'FAIL: run this block under bash — PIPESTATUS is a bash array and zsh expands it empty'; exit 2; }
_T0="$(timing_now_ms)"
TILLANDSIAS_SMOKE_LOCK_LOG=target/smoke-e2e/00-smoke-lock.log \
  scripts/with-smoke-lock.sh --name release-smoke-e2e -- \
  podman system reset --force 2>&1 | tee target/smoke-e2e/02-reset.log
RESET_RC=${PIPESTATUS[0]}; printf 'reset_exit=%s\n' "$RESET_RC" | tee target/smoke-e2e/02-reset-exit.txt
  # 900-z3kv (operator ruling 2026-09-13, landed by yoga): the reset is the baseline, and
  # an empty podman store is not a cold room — clear the host-held Vault credentials
  # (keychain items, ~/.cache/tillandsias/fallback_*, the vault-data dir) in the SAME
  # step, or the next --init resyncs the old share and the clean room is not one
  # (drill: plan/issues/fleet-restart-2026-09-12.md, 900-z3kv COMPLETED).
  scripts/clear-vault-host-credentials.sh 2>&1 | tee -a target/smoke-e2e/02-reset.log
  CLEAR_RC=${PIPESTATUS[0]}; printf 'clear_exit=%s\n' "$CLEAR_RC" | tee target/smoke-e2e/02-clear-exit.txt
  test -n "$CLEAR_RC" && test "$CLEAR_RC" -eq 0
timing_emit smoke-destructive-reset smoke "$_T0" "${RESET_RC:-1}" || true
test -n "$RESET_RC" && test "$RESET_RC" -eq 0
```

Confirm afterward that the store is empty:
```bash
CONTAINERS="$(podman ps -aq)"; VOLUMES="$(podman volume ls -q)"; IMAGES="$(podman images -q)"
printf '[containers]\n%s\n[volumes]\n%s\n[images]\n%s\n' "$CONTAINERS" "$VOLUMES" "$IMAGES" \
  | tee target/smoke-e2e/02-empty-store.txt
test -z "$CONTAINERS"; test -z "$VOLUMES"; test -z "$IMAGES"
```

**`0 volumes` is not `Vault's data is gone`, and the gap ran for ~2.5
months.** Every Linux pass asserted an empty podman store while `--init`
logged `preserving existing data volume` — both true, about different
things: `vault_data_volume_exists()` tests `init_cache_dir()/vault-data`, a
HOST DIRECTORY, not a podman volume. Assert that directory is absent too, in
the same block as the three `test -z` lines above:

```bash
VAULT_DATA_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/tillandsias/vault-data"
{ echo "[vault-data-dir]"; ls -la "$VAULT_DATA_DIR" 2>&1; } | tee target/smoke-e2e/02-vault-data-dir.txt
test ! -e "$VAULT_DATA_DIR"
```

`scripts/clear-vault-host-credentials.sh` removes it but only best-effort —
it is written from inside a container under a subuid, so a rootless `rm -rf`
can be refused and the script still exits 0 with a `warn:` line. A
`0-volumes` PASS beside a surviving `vault-data/` is a clean-room claim the
run cannot support (drill: plan/issues/fleet-restart-2026-09-12.md, 900-z3kv criterion 1 DECIDED: (a)).

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
scripts/e2e-step2-macos.sh target/smoke-e2e
test ! -e "$HOME/Library/Application Support/tillandsias"
MACOS_RESIDUE="$(cat target/smoke-e2e/02-macos-residue.txt)"
test -z "$(printf '%s' "$MACOS_RESIDUE" | tail -n +2)"
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
#
# ORDER 1004-vsh2. `cmdkey /list:<target>` ECHOES THE TARGET IN ITS HEADER
# even when no such credential exists, so the obvious predicate
# `$out -match [regex]::Escape($cred)` is TRUE FOR EVERY TARGET and the
# verifier below threw on every run. Measured on yolanda 2026-09-04:
#
#   /list:definitely-not-a-real-target-12345  ->  exit 0, 4 lines
#     "Currently stored credentials for definitely-not-a-real-target-12345:"
#     "* NONE *"
#   /list:<a target that exists>              ->  exit 0, 7 lines
#     "Currently stored credentials for <target>:"
#     "    Target: <target>"   <- the record, and the second echo
#
# THE EXIT CODE DOES NOT DISCRIMINATE: cmdkey returns 0 for both, so the
# locale-proof status predicate is not available and was not used. Measured,
# not assumed.
#
# So count the ECHOES OF THE TARGET NAME, which is the one string in that
# output that Windows does not localize: the header echoes it once; a real
# record echoes it again on its own `Target:` line. 1 = absent, >=2 = present.
# Do NOT test for the absence of "* NONE *" or match the header text -- both
# are LOCALIZED, and an English-text predicate trades a bug that fails on
# every run for one that fails only on some operators' machines, which is
# strictly worse because it fails where nobody is looking.
function Test-TillandsiasCredPresent([string] $target) {
    $out = & cmdkey.exe "/list:$target" 2>$null
    (($out | Where-Object { $_ -match [regex]::Escape($target) }) | Measure-Object).Count -ge 2
}

foreach ($cred in @('vault-shamir-share-v1', 'vault-root-token-v1')) {
    if (Test-TillandsiasCredPresent $cred) { & cmdkey.exe "/delete:$cred" > $null 2>&1 }
}
$stillThere = @('vault-shamir-share-v1', 'vault-root-token-v1') |
    Where-Object { Test-TillandsiasCredPresent $_ }
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
[ -n "${BASH_VERSION:-}" ] || { echo 'FAIL: run this block under bash — PIPESTATUS is a bash array and zsh expands it empty'; exit 2; }
_T0="$(timing_now_ms)"
TILLANDSIAS_SMOKE_LOCK_LOG=target/smoke-e2e/00-smoke-lock.log \
  scripts/with-smoke-lock.sh --name release-smoke-e2e -- \
  tillandsias --debug --init 2>&1 | tee target/smoke-e2e/03-init.log
INIT_RC=${PIPESTATUS[0]}
timing_emit smoke-init-pristine smoke "$_T0" "${INIT_RC:-1}" || true; printf 'init_exit=%s\n' "$INIT_RC" | tee target/smoke-e2e/03-init-exit.txt
test -n "$INIT_RC" && test "$INIT_RC" -eq 0
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

### macOS

**The block above is Linux-only and there is no `tillandsias` CLI on macOS** —
the installed bundle ships `tillandsias-tray`. The Host Matrix has always said
this lane re-provisions with `--provision` + `--diagnose --json`; the step had
no macOS block to match, so the lane the matrix promises was unexecutable as
written. Added 2026-08-26, before this lane's first run against a published
release.

> **A 300 s `wait_phase_ready` timeout on macOS is answered FIRST by
> `/var/log/tillandsias-provision-marker` inside the guest** (1055-e8ie). Read
> it with
> `…/tillandsias-tray --exec-guest 'cat /var/log/tillandsias-provision-marker'`.
> It says in one file whether the cloud-init provisioning script COMPLETED,
> and if not, the exact line it died on plus `systemctl --failed` and
> `systemctl status` for the headless units at that moment.
>
> WHY THIS IS THE FIRST THING TO READ, not the last: the guest boots fine,
> networks, reaches a login prompt and installs its binary while failing to
> provision — because the script is `set -euo pipefail` and cloud-init does
> NOT surface a user-script failure, so `cloud-init status` still reports
> `done, errors: []`. Measured 2026-09-05: the script aborted at its
> `systemctl start` of the headless units, and the readiness-service start on
> the VERY NEXT LINE never ran, so the guest could not report Ready. Nothing
> anywhere said so. Four hypotheses were spent before the marker existed;
> reading it now costs one command.

```bash
[ -n "${BASH_VERSION:-}" ] || { echo 'FAIL: run this block under bash — PIPESTATUS is a bash array and zsh expands it empty'; exit 2; }
APP="/Applications/Tillandsias.app/Contents/MacOS/tillandsias-tray"
IMG="$HOME/Library/Application Support/tillandsias/rootfs.img"

# Marker to prove the image below was built AFTER the destruction, not
# inherited from it. `test -nt` is POSIX and needs no date arithmetic.
touch target/smoke-e2e/03-destruction-marker

"$APP" --provision 2>&1 | tee target/smoke-e2e/03-provision.log
PROVISION_RC=${PIPESTATUS[0]}
printf 'provision_exit=%s\n' "$PROVISION_RC" | tee target/smoke-e2e/03-provision-exit.txt
test -n "$PROVISION_RC" && test "$PROVISION_RC" -eq 0

# A fresh image, not a survivor. An exit code cannot tell these apart.
test -f "$IMG"
test "$IMG" -nt target/smoke-e2e/03-destruction-marker

# LAST — after every mutating step above. If anything below this line mutates
# the host, this report is stale and the run is unfinished (the 2026-08-10
# incident: 4/4 PASS on a health check taken before one more mutating step
# wedged the host for 25 minutes).
_T0="$(timing_now_ms)"
"$APP" --diagnose --json 2>&1 | tee target/smoke-e2e/03-diagnose.json
_rc=${PIPESTATUS[0]}
timing_emit smoke-health-check smoke "$_T0" "${_rc:-1}" || true
test -n "$_rc" && test "$_rc" -eq 0

jq -e '.provisioned == true'    target/smoke-e2e/03-diagnose.json
jq -e '.rootfs_present == true' target/smoke-e2e/03-diagnose.json
# The tray's OWN version, a second surface for the step-1 assertion. Truthful
# only since 635-bhkb; it read the frozen crate version "0.1.0" before.
jq -e --arg v "${SMOKE_TAG#v}" '.version == $v' target/smoke-e2e/03-diagnose.json
```

> **`release_tag` is NOT the release version — it is the guest image tag**
> (`fedora-44`). Asserting it against `$SMOKE_TAG` fails for a reason that has
> nothing to do with the release, and reads like a real defect. Measured
> 2026-08-26 while writing this block.
>
> **`guest_version` and `guest_binary_staged_matches_bundle` are `null` under a
> plain `--diagnose`** — they need a live VM, i.e. `--with-metrics`, which
> BOOTS. Do not assert them here; a `null == null` check would pass forever
> without ever testing anything, which is the class this runbook has already
> been bitten by twice. Exercise the guest/tray skew check under
> `--with-metrics` if you want it, and note that it is a mutating step, so the
> `--diagnose` above must then be re-run after it.

### Windows

> **This block is not runnable on its own.** It assumes §1 installed the tray
> and §2 unregistered the distro. Run alone it fails twice and both failures
> lie: `Get-Command tillandsias-tray.exe -ErrorAction Stop` throws on line 2 on
> a host where §1 never installed it, and the destruction-marker assertion
> reports "a survivor, not a fresh provision" when the truth is that nothing
> destroyed it. The runnable unit is §1 + §2 + §3, never §1 + §3 (order
> 1004-vsh2 — an instruction to run "§1 and §3" was issued and measured
> unrunnable on yolanda before it was executed).

**Neither block above runs on Windows and there is no `tillandsias` CLI there
either** — the installed surface is `tillandsias-tray.exe`, and its
provisioning flag is `--provision-once`, NOT the macOS `--provision` (the two
are not interchangeable: `tillandsias-tray.exe --help`). The Host Matrix has
promised this lane since the Windows installer shipped; no block matched it,
so every Windows run improvised and no two runs were comparable. Added
2026-09-04 (order 1004-fue3) from esme-windows's improvised v56.9.2.1 run on
esmeraldinha (cold `--provision-once` exit 0 in 117 s, warm 18 s, wire Ready).

```powershell
$ErrorActionPreference = 'Stop'
# Same resolution as §1 — the installer does not add its directory to PATH
# (measured 2026-09-04, order 1004-vsh2), so `Get-Command` alone throws here.
$tray = (Get-Command tillandsias-tray.exe -ErrorAction SilentlyContinue |
    Select-Object -First 1 -ExpandProperty Source)
if (-not $tray) { $tray = "$env:LOCALAPPDATA\Programs\Tillandsias\tillandsias-tray.exe" }
if (-not (Test-Path $tray)) { throw "tray not found on PATH or at $tray (did §1 run?)" }

# Marker to prove the distro below was registered AFTER §2's unregister, not
# inherited from it. An exit code cannot tell these apart.
New-Item -ItemType File -Force target\smoke-e2e\03-destruction-marker | Out-Null

# Cold provision from pristine. `--provision-once` provisions and EXITS; it is
# the headless form the tray's own --help prescribes for scripted use.
& $tray --provision-once *>&1 | Tee-Object target\smoke-e2e\03-provision.log
$provisionExit = $LASTEXITCODE
"provision_exit=$provisionExit" | Tee-Object target\smoke-e2e\03-provision-exit.txt
if ($provisionExit -ne 0) { throw "provision-once failed (exit $provisionExit)" }

# A fresh distro, not a survivor: it must exist, and its rootfs must postdate
# the marker (WSL2 keeps each distro's ext4.vhdx under LOCALAPPDATA).
$distros = (wsl.exe -l -q) -replace "`0", '' | ForEach-Object { $_.Trim() }
if ($distros -notcontains 'tillandsias') { throw "distro 'tillandsias' not registered after provision" }
$vhdx = Get-ChildItem -Path $env:LOCALAPPDATA -Recurse -Filter ext4.vhdx -ErrorAction SilentlyContinue |
  Where-Object { $_.FullName -match 'tillandsias' } | Sort-Object LastWriteTime -Descending | Select-Object -First 1
if (-not $vhdx) { throw "no ext4.vhdx for the tillandsias distro under $env:LOCALAPPDATA" }
if ($vhdx.LastWriteTime -lt (Get-Item target\smoke-e2e\03-destruction-marker).LastWriteTime) {
  throw "rootfs $($vhdx.FullName) predates the destruction marker — a survivor, not a fresh provision"
}

# Wire state at provision exit, POLLED to Ready: `--status-once --json` is
# read-only, and Ready can lag the provision exit by a few seconds; it can
# also LAPSE later (see the note below), so the poll starts immediately and
# gives up loudly rather than sleeping first.
$deadline = (Get-Date).AddSeconds(60); $status = $null; $statusExit = 1
do {
  & $tray --status-once --json 2>&1 | Tee-Object target\smoke-e2e\03-status.json | Out-Null
  $statusExit = $LASTEXITCODE
  if ($statusExit -eq 0) { $status = Get-Content target\smoke-e2e\03-status.json -Raw | ConvertFrom-Json }
  if ($status -and $status.phase -eq 'Ready') { break }
  Start-Sleep -Seconds 5
} while ((Get-Date) -lt $deadline)
"status_exit=$statusExit phase=$($status.phase) podman_ready=$($status.podman_ready)" | Tee-Object target\smoke-e2e\03-status-summary.txt
if ($statusExit -ne 0) { throw "status-once failed (exit $statusExit)" }
if ($status.phase -ne 'Ready') { throw "phase is '$($status.phase)' after 60 s, expected Ready" }
if (-not $status.podman_ready) { throw "podman_ready is false at Ready" }

# LAST — after every mutating step above. If anything below this line mutates
# the host, this report is stale and the run is unfinished (the 2026-08-10
# incident, same rule as the macOS block).
& $tray --diagnose --json 2>&1 | Tee-Object target\smoke-e2e\03-diagnose.json
$diagnoseExit = $LASTEXITCODE
"diagnose_exit=$diagnoseExit" | Tee-Object target\smoke-e2e\03-diagnose-exit.txt
# DO NOT assert `$diagnoseExit -eq 0`, and the reason is the note above.
#
# MEASURED 2026-09-04 on yolanda (order 1004-vsh2), inline in ONE script with
# nothing interposed: --status-once read Ready / podman_ready=true, and
# --diagnose seconds later exited 2 with distro_running=false and
# wire.reachable=false. The tray log shows the wire closing ~15 s after
# "provision-once: VM Ready". Nothing holds the guest open, so by the time the
# LAST step runs the wire is legitimately down and diagnose reports that
# truthfully. Requiring exit 0 here contradicts this block's own
# "Ready is not durable after --provision-once" note, one screen up.
#
# So assert what diagnose is FOR at this point in the lane — a well-formed
# report carrying this tray's identity — and record the exit code as data.
# A missing or unparseable report is still a hard failure.
if (-not (Test-Path target\smoke-e2e\03-diagnose.json)) { throw "diagnose wrote no report" }
$diag = Get-Content target\smoke-e2e\03-diagnose.json -Raw | ConvertFrom-Json
if (-not $diag) { throw "diagnose report is not valid JSON (exit $diagnoseExit)" }
if ($diag.PSObject.Properties.Name -contains 'version') {
  if ($diag.version -ne $SmokeTag.TrimStart('v')) { throw "tray version '$($diag.version)' != release $SmokeTag" }
} else {
  "diagnose --json carries no 'version' field on this build — the release-tag assertion for the tray is UNMET, record it as a finding" |
    Tee-Object -Append target\smoke-e2e\03-diagnose-notes.txt
}
```

> **Ready is not durable after `--provision-once`** (esme, finding
> `smoke-finding/windows-ready-not-durable-after-provision-once`, order
> 1004-* series): nothing holds the guest open once the headless provision
> exits, so a `--status-once` taken a minute later can read exit 1 while the
> block above, taken immediately, reads Ready. Both are true. This block
> asserts the state AT provision exit, which is what the lane promises; do not
> re-run `--status-once` later and file its exit 1 as a provision failure.
>
> **Every assertion here reads `$LASTEXITCODE` from a native call, never
> `$?` from a pipeline** — `$?` after `... | Tee-Object` is Tee-Object's
> status, which is how the §1 Windows install asserted nothing for a year.

---

## 3b — Stop the substrate and assert every container exits cleanly

**Run this after §3, before §4.** It is where order `1134-u934` was found and
it costs one stop.

**Why it is its own step rather than a line in §3.** §3 asserts that a
pristine `--init` reaches a healthy state, and it did — the run that filed
`1134-u934` was §1/§2/§3 all PASS with zero occurrences of every failure class
§3 enumerates. The defect was in SHUTDOWN, so a lane that stops at "init was
clean" cannot see it in principle, however carefully it reads `03-init.log`.
It was found only by looking at what the tray's own `Graceful shutdown
completed` line actually produced: `tillandsias-vault  Exited (137)` — killed
after stalling the full 30 s grace — next to `tillandsias-proxy  Exited (0)`
in the same shutdown.

**Assert BOTH halves, per container.** Elapsed alone passes a container that
exits fast for a bad reason; exit code alone passes one that burns the whole
grace and is then reported 0. 137 specifically means the grace expired and the
container was SIGKILLed.

```bash
# Linux. Record the grace each container declares — they differ — then stop
# them all and read what podman recorded, container by container.
podman ps --format '{{.Names}}' | tee target/smoke-e2e/3b-running.txt
for c in $(cat target/smoke-e2e/3b-running.txt); do
  grace="$(podman inspect "$c" --format '{{.Config.StopTimeout}}')"
  t0="$(date +%s)"
  podman stop -t "$grace" "$c" >/dev/null 2>&1
  t1="$(date +%s)"
  printf '%s elapsed=%ss grace=%ss exit=%s oom=%s\n' "$c" "$((t1 - t0))" "$grace" \
    "$(podman inspect "$c" --format '{{.State.ExitCode}}')" \
    "$(podman inspect "$c" --format '{{.State.OOMKilled}}')"
done | tee target/smoke-e2e/3b-shutdown.txt

# The verdict. A non-zero exit OR an elapsed at/above the grace is a finding
# per container, not a run-level FAIL — the enclave is already destroyed and
# rebuilt by this point, so §4 may still proceed on a clean §3.
awk '{
  split($2, e, "="); split($3, g, "="); split($4, x, "=")
  if (x[2] != 0 || e[2] + 0 >= g[2] + 0) { print "FINDING: " $0; bad++ }
} END { printf "3b: %d container(s) did not stop cleanly\n", bad + 0 }' \
  target/smoke-e2e/3b-shutdown.txt | tee target/smoke-e2e/3b-verdict.txt
```

A container that fails here is a **`plan/issues` work packet per §5**, and the
packet must name the process tree, not just the exit code — read it from the
running container BEFORE the stop:

```bash
podman exec <container> sh -c 'for p in /proc/[0-9]*; do echo "$(basename $p) $(cat $p/comm 2>/dev/null)"; done'
```

`1134-u934` is why. Its entrypoint was a PID-1 shell that trapped nothing, and
the pid it held was `tee`'s rather than the server's, because `$!` after a
backgrounded PIPELINE is the LAST stage. The obvious one-line trap forwarding
to that pid signals `tee`, leaves the 30 s and the 137 exactly as they are, and
**looks correct**. The tree (`1 bash / 10 vault / 11 tee`) is what separates
the two, and it is not readable from the script's text.

`scripts/test-vault-shutdown-forwards-sigterm.sh` is the standing single-
container form of this step for vault, and exits 3 (`could-not-run`) rather
than 0 on a host with no provisioned enclave.

> **macOS and Windows.** The substrate is a Virtualization.framework VM and a
> WSL2 distro, not host podman, so the loop above runs INSIDE the guest or not
> at all. Neither lane asserts guest-container shutdown today; that is a
> stated gap, not a silent pass — record it rather than reporting 3b clean.

## 4 — Forge continuous-enhancement run (only if Step 3 was clean)

```bash
[ -n "${BASH_VERSION:-}" ] || { echo 'FAIL: run this block under bash — PIPESTATUS is a bash array and zsh expands it empty'; exit 2; }
_T0="$(timing_now_ms)"
timing_begin smoke-forge-lane smoke
TILLANDSIAS_SMOKE_LOCK_LOG=target/smoke-e2e/00-smoke-lock.log \
  scripts/with-smoke-lock.sh --name release-smoke-e2e -- \
  env TILLANDSIAS_NO_TRAY=1 tillandsias . --opencode --prompt "Use the /meta-orchestration skill" 2>&1 \
  | tee target/smoke-e2e/04-opencode.log
LANE_RC=${PIPESTATUS[0]}; printf 'opencode_exit=%s\n' "$LANE_RC" | tee target/smoke-e2e/04-opencode-exit.txt
timing_commit smoke-forge-lane smoke "$_T0" "${LANE_RC:-1}"
```

> **THIS IS THE STEP MOST LIKELY TO LOSE ITS SUPERVISOR, so it is the one that
> stamps** (order 1026-ps4n). `timing_begin` writes the start to disk before
> the lane runs; `timing_commit` emits the real record and clears the stamp. If
> the shell running this block is killed, the stamp survives and the NEXT run's
> `timing_reap` (§0) emits `smoke-forge-lane-supervisor-lost` instead of
> nothing. The lost record is reported under a DIFFERENT step name on purpose:
> the recurrence rung groups by step, so a lower-bound duration from a killed
> run can never be averaged into real `smoke-forge-lane` timings.
>
> **RUN IT DETACHED ON A FLOOR HOST.** A detached run survived on pirria where
> a plain backgrounded run did not, because the kill takes the process group.
> Detaching does not make the host less short of memory — it stops the
> supervisor being collateral.
>
> **THE FORM DIFFERS BY PLATFORM AND macOS HAS NO `setsid`** (macneo,
> 2026-09-15): `setsid nohup <script-file> < /dev/null > log 2>&1 &` on Linux,
> `nohup <script-file> < /dev/null > log 2>&1 & disown` on macOS. This runbook
> named only the Linux form, which fails outright on both Macs — and this is
> the lane most likely to be run on one, since a curl-install smoke is floor
> work. A script FILE and a terminal `rc=` marker are required on both.

### 4a — What a killed supervisor looks like, and what it is not

**Containers alive, wrapper gone.** Measured on pirria 2026-09-04: the agent
harness reported "system is running low on memory" and killed the shell running
§4; `journalctl` showed **no kernel oom-kill**; all six enclave containers
including inference were **still up and healthy 56 minutes later**. Only the
supervising bash died. The same lane had completed in 71m30s that morning on
the same host, so the condition is **marginal, not deterministic** — it fails
intermittently, which is worse than failing reliably, because the floor's
largest measurement is the one least likely to be captured.

Read that state correctly: **the lane did not fail.** A reader who sees the
wrapper gone and concludes the release is broken is reading a host-resource
event as a product defect. The discriminating checks, in order:

```bash
podman ps --format '{{.Names}} {{.Status}}'   # lane containers still Up? -> the lane lives
journalctl --since '1 hour ago' | grep -iE 'oom-kill|Killed process'   # empty -> not the kernel
```
Containers up **and** no kernel oom-kill means the supervisor was killed by the
agent harness, not the product and not the OOM killer. The run is unfinished,
not red.

**The memory floor this step needs.** The forge lane brings up six containers
(vault, proxy, router, git, inference, forge). Measured on **pirria, 15 GiB
total, 4 cores**: the lane itself completes, and it is the *supervisor* that
gets sacrificed under pressure — so 15 GiB is **at** the boundary, not below
it. No host with less has been measured, and no host above 16 GiB has reported
this, so the honest statement is a boundary observation and not a threshold:
**at 15 GiB the wrapper is collateral; the number at which it stops being is
unmeasured.** Do not invent one. If a host with 8 or 32 GiB runs this step,
record which side of the line it lands on and the floor gets a real threshold
instead of a single point.

> The guard and the `LANE_RC` capture arrived with the timing wrapper
> (1013-qv7c). This block had neither: it piped to `tee` and recorded no status
> at all, so a forge lane that failed to launch left the same evidence as one
> that completed. Emitting a duration without an exit code would have recorded
> *how long the failure took* and called it a measurement, so the capture is
> part of the record, not scope creep — the 727-kmks assertion shape, arriving
> at the one step that never had it.

### 4a-cold — `opencode_exit=0` IS NOT THE PASS CONDITION ON A POST-RESET HOST

**Read this before you read `LANE_RC`.** Order 1190-swen; coordinator ruling
2026-09-14, option (a).

§2 reset the substrate, so Vault is **cold** and holds no GitHub token. The
in-forge lane therefore reaches the Credential Channel Guard and **hard-stops
there, deterministically, before any committable work**. That is not a
degraded run. On a post-reset host it is the *only* correct outcome, and it is
what §4 exercises: enclave bring-up, and the guard. Nothing past them.

The failure this replaces is a reader — human or orchestrator — seeing
`opencode_exit=0` and concluding the forge did a cycle's worth of work. It did
not. It could not have.

**ASSERT THE GUARD LINE, NEVER THE EXIT CODE:**

```bash
# PASS on a cold (post-§2-reset) host: the lane came up and stopped AT the guard.
if grep -qE 'blocked:upstream-(no-credential|auth-unpublished)' target/smoke-e2e/04-opencode.log; then
    echo "cold-host PASS: lane reached the credential guard and stopped there"
else
    echo "FINDING: no credential-guard stop in the lane log on a post-reset host."
    echo "  A cold Vault holds no token, so the guard MUST have refused."
    echo "  Either the guard was skipped, or this room was not clean."
fi | tee target/smoke-e2e/04a-cold-host-outcome.txt

# NEGATIVE CONTROL — exit 0 WITHOUT the guard line FAILS the assertion.
# This is the whole point: the two are independent, and only the second is evidence.
grep -qE 'blocked:upstream-(no-credential|auth-unpublished)' target/smoke-e2e/04-opencode.log   || echo "negative control fired: opencode_exit=${LANE_RC} is NOT a pass on its own"
```

Then confirm the lane left nothing behind, which is the other half of "stopped
before committable work":

```bash
{
  echo "git_status_empty=$([ -z "$(git status --porcelain)" ] && echo yes || echo no)"
  echo "head_matches_origin=$([ "$(git rev-parse HEAD)" = "$(git rev-parse origin/linux-next)" ] && echo yes || echo no)"
  # ORDER 1190-swen, CORRECTED 2026-09-20. This greped `^MO-FULL: `
  # GENERICALLY and was WRONG: a guard-stopped cycle is SUPPOSED to emit
  # `MO-FULL: BLOCKED`. The meta-orchestration skill sanctions it explicitly
  # (`MO_FULL_DISPOSITION=BLOCKED scripts/mo-full-attest.sh self`, and "BLOCKED
  # is exempt: a cycle saying it did not finish must still be able to say so").
  # MEASURED on pirria 2026-09-20: a lane that behaved exactly as designed —
  # enclave up, `blocked:upstream-no-credential`, nothing claimed or pushed —
  # emitted `MO-FULL: BLOCKED 7e33445f9 linux-next 7e33445f9` and this check
  # flagged it, which would send the next reader to investigate a correct run.
  # What must be absent is a COMPLETE marker: that is the claim a guard-stopped
  # cycle has no right to make.
  echo "mo_full_complete_present=$(grep -qE '^MO-FULL: COMPLETE ' target/smoke-e2e/04-opencode.log && echo yes || echo no)"
  echo "mo_full_blocked_present=$(grep -qE '^MO-FULL: BLOCKED ' target/smoke-e2e/04-opencode.log && echo yes || echo no)"
} | tee target/smoke-e2e/04a-cold-host-residue.txt
```

Expected on a cold host: `yes`, `yes`, **`no`** for COMPLETE, and either value
for BLOCKED. The absent COMPLETE marker is correct and loud — a lane that
stopped at the guard has not completed its exit contract and must not claim it
did. A `BLOCKED` marker is NOT a finding: it is the cycle correctly saying it
did not finish, and a run that emits one has behaved better than a run that
emits nothing, because the disposition is then on the record rather than
inferred from silence.

MEASURED on pirria 2026-09-14 (`04-opencode.log:848-862`): the guard answered
`blocked:upstream-no-credential` (exit 1); the mirror published
`refs/tillandsias/upstream-auth/no-credential`, fresh; the in-forge agent
claimed nothing, drained nothing, filed nothing, committed nothing, left
`git status` empty and `HEAD == origin/linux-next`, and emitted no `MO-FULL:`
marker — correctly refusing to commit from a container about to be destroyed.
The HOST could push at that same moment
(`00-credential-channel.txt` = `ok:gh-keyring-push-verified`). **The asymmetry
is the design, not a defect**, and the in-forge handling is not what needed
fixing — the runbook's pass condition was.

**Option (b) — issue a scoped token after §3 — was DECLINED** by the
coordinator, and the reason generalises: it would test a different machine than
the one this smoke exists to prove. **A clean room that holds a credential is
not a clean room.**

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

**The trace alone is NOT the finding.** A healthy run prints that same line
WITH a `keeping application-lifetime: tillandsias-vault, tillandsias-proxy,
tillandsias-router, tillandsias-nix-cache` clause — that is the order-298 fix
working, not regressing (pirria, v56.9.2.1 floor smoke, 2026-09-04: the line
was present, the proxy was alive, and a reader grepping the string alone would
have filed a false regression). The assertion is proxy LIVENESS while the lane
is up, taken by a concurrent watcher, never a grep for the trace. Take it while
the lane is up, not after: lane-scoped containers are torn down on exit by
design, and only the application-lifetime set must survive.

### 4c — Final health check (Linux)

**LAST — after every mutating step above**, the same rule the macOS and Windows
lanes already carry (the 2026-08-10 incident: 4/4 PASS on a health check taken
before one more mutating step wedged the host for 25 minutes).

```bash
[ -n "${BASH_VERSION:-}" ] || { echo 'FAIL: run this block under bash — PIPESTATUS is a bash array and zsh expands it empty'; exit 2; }
_T0="$(timing_now_ms)"
{
  echo "=== containers ==="
  podman ps --format '{{.Names}}\t{{.Status}}'
  echo "=== vault health ==="
  podman exec tillandsias-vault sh -c \
    'curl -s --cacert /run/secrets/tillandsias-vault-tls-ca https://127.0.0.1:8200/v1/sys/health?standbyok=true'
  echo
  echo "=== version ==="
  tillandsias --version
} 2>&1 | tee target/smoke-e2e/05-health.log
_rc=${PIPESTATUS[0]}
timing_emit smoke-health-check smoke "$_T0" "${_rc:-1}" || true
test -n "$_rc" && test "$_rc" -eq 0
grep -q '"sealed":false' target/smoke-e2e/05-health.log
grep -q '^tillandsias-proxy' target/smoke-e2e/05-health.log
```

Expect the application-lifetime set (`tillandsias-vault`, `tillandsias-proxy`,
`tillandsias-router`) up and healthy, and the lane-scoped ones
(`tillandsias-inference`, `tillandsias-git-*`, the forge) gone — §4b's teardown
is by design, so their ABSENCE here is the pass, not a finding.

> **There was no Linux health-check block until 1013-qv7c**, though the Host
> Matrix promises the step and the macOS/Windows lanes both implement it. The
> gap is not cosmetic: `tillandsias --diagnostics` reads like the command to
> reach for and is NOT one — it is a MODIFIER ("stream real-time logs from all
> enclave containers (implies `--debug`)"), so bare, with no subcommand, it
> falls through to the default tray launch and starts a cloud refresh. Measured
> on pirria 2026-09-04, which ran it as the final health check of the
> v56.9.2.1 smoke and had to kill it: a "health check" that mutates is exactly
> what the LAST rule above exists to prevent. The block above is what that run
> used instead, after the fact.

## 5 — File the findings report

> **This heading did not exist until order 1189-7yvu/1190-swen.** Five places
> in this runbook say "see §5" or "the §5 report" (§0.2b, §3, §3b, §4, §4a-cold)
> and a reader following any of them found no §5 — the section was here,
> unnumbered, after §4c. A cross-reference to a section that cannot be located
> is the cheapest kind of broken instrument.

**The report MUST open with these three lines**, before any packet:

```markdown
- run_start: <the `run_start=` value from target/smoke-e2e/00-run-start.txt>
- evidence_dir: target/smoke-e2e   (previous runs archived under _archived-<ts>/)
- forge_lane_outcome: <see below — required whenever §4 ran>
- signature_verification: <the `cosign:` line §1s emitted, VERBATIM — required always>
```

`signature_verification` carries §1s's line unchanged: `cosign:verified:<n>/<n>`,
`cosign:could-not-run:<reason>`, or `cosign:FAILED:<asset>` (order 1273-4mak).

**A run whose line is `cosign:could-not-run:` MUST NOT be reported as an
unqualified PASS.** Write the verdict as `PASS (signatures unverified: <reason>)`.
This is the requirement that closes the gap rather than re-declaring it: the
08-28 Linux, 08-28 Windows and 09-19 macOS reports all recorded the missing
signature check honestly, under "NOT CHECKED", and the gap still shipped three
times — because declaring it cost nothing and the headline still said PASS.
A reader who sees only the verdict must not be able to miss that authenticity
was not established.

`could-not-run` is NOT a failure. A host without cosign has not found a bad
signature; it has found nothing, and reporting nothing as a failure would make a
floor host look like a security incident. It is a third verdict, and it must be
visible.

`run_start` is what makes every other file in the evidence directory checkable
(order 1189-7yvu). Without it a reader cannot tell this run's `03-init-exit.txt`
from a previous run's, because they have the same name — and on pirria
2026-09-14 a 2026-09-13 `init_exit=0` was read as that run's result while its
`--init` was still building the proxy image.

`forge_lane_outcome` must say, **in words a reader cannot mistake for a
completed cycle** (order 1190-swen), which of these happened:

- `cold-host guard stop (EXPECTED PASS)` — the lane brought the enclave up and
  stopped at the Credential Channel Guard with
  `blocked:upstream-no-credential`. Nothing was claimed, drained, filed or
  committed; the tree is pristine; **no `MO-FULL:` marker was emitted, and its
  absence is correct.** On a post-§2-reset host this is the expected outcome,
  not a partial one. Say so explicitly — do NOT write "forge run clean", which
  reads as a cycle's worth of work.
- `completed cycle` — only legitimate if the lane got past the guard, which on
  a properly cold host it cannot. If you are writing this after a §2 reset,
  something held a credential and **the room was not clean** — that is a
  finding, not a pass.
- `supervisor lost` — see §4a; containers up and no kernel oom-kill means the
  run is unfinished, not red.

**Never report the forge lane from `opencode_exit` alone.** Exit 0 and a
guard-stop are the same number.

Each finding becomes a `### Work Packet:` entry so `/advance-work-from-plan` can
claim and fix it. Append packets to a dated, **host-qualified** smoke report:

```
plan/issues/smoke-e2e-findings-<RELEASE_TAG>-<DATE>-<host_kind>-<host_id>.md
```

e.g. `smoke-e2e-findings-v56.9.11.1-2026-09-12-macos-macbookair.md`.

**THE HOST FIELDS ARE NOT DECORATION — WITHOUT THEM TWO LANES COLLIDE IN GIT.**
This template read `<RELEASE_TAG>-<DATE>` until 2026-09-12, while the convention
in practice had always carried a host (`plan/smoke-e2e-v0.4.260815.1-windows.md`
in-tree; the README row for v0.4.260826.1 cites `…-macos-…-macbook.md`,
`…-windows-…-yolanda.md`, `…-linux-…-yoga.md`). A three-platform release asks
every lane to smoke the same tag on the same day, so the dropped field made a
collision *certain*, not unlucky: on 2026-09-12 yoga's Linux report and
macbookair's macOS report were both written to
`smoke-e2e-findings-v56.9.11.1-2026-09-12.md`, and
`land-on-platform-branch.sh` refused with `refused:land:trunk-merge-conflict`
(add/add). Recorded on order 1004-fue3.

**On such a conflict, KEEP BOTH LANES' REPORTS.** The conflict surfaces at LAND
time, on a host that did nothing wrong, and the obvious resolution — take one
side — silently destroys another platform's entire smoke result, including its
NOT CHECKED list and any findings only that platform could have seen. Give each
side its host-qualified name; never resolve by choosing. If one side already
sits at an unqualified path on trunk, leave it there (renaming another host's
landed file is that host's call) and qualify yours.

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
- **No silent passes.** If the smoke ran clean end-to-end, still write a
  one-line PASS entry to the report (release tag + "init clean") so the
  convergence record shows the release was exercised. **Do not write "forge run
  clean"** — state the `forge_lane_outcome` from the top of this section
  instead. On a post-reset host the honest line is "init clean; forge lane
  stopped at the credential guard as expected", and the old wording is exactly
  the sentence order 1190-swen exists to remove.
- **Cite the release's ledger row and account for its claims** (order 380). The
  report carries a short `## Ledger claims` section listing each claim from the
  row read in §0.2b under exactly one of three headings:
  **EXERCISED** (this lane checked it — say how),
  **NOT APPLICABLE** (the claim is another platform's, or another lane's), or
  **NOT CHECKED** (this lane could have and did not).
  The third heading is the one that earns this section. A report with no
  NOT-CHECKED list reads as though the run covered everything the release
  claimed, and a reader has no way to tell that from a run that simply never
  looked. Naming the gaps is what makes a PASS mean something narrower and
  truer than "the release works".

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
