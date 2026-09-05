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

A fresh `--init` re-initializes Vault and re-captures the keychain-held unseal
share, so the keychain↔volume resync brick (see git history `738059bc`) is part
of what this smoke exercises — if init bricks, that is a finding, not a failure
to hide.

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
4. **Create a findings log dir** the smoke will append to:
   ```bash
   mkdir -p target/smoke-e2e
   ```
5. **Source the timing helpers, and keep them sourced for every block below**
   (order 1013-qv7c). Each smoke step emits ONE duration record so the
   recurrence rung (`repeat:` / `recur:` / `skippable:` in
   `scripts/cycle-metrics.sh`) can see this runbook's work:
   ```bash
   . "$PWD/scripts/timing-log.sh" 2>/dev/null || true
   command -v timing_emit >/dev/null 2>&1 || { timing_now_ms() { echo 0; }; timing_emit() { return 0; }; }
   ```
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
if ($installedVersion -notmatch [regex]::Escape($SmokeTag.TrimStart('v'))) {
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

## 4 — Forge continuous-enhancement run (only if Step 3 was clean)

```bash
[ -n "${BASH_VERSION:-}" ] || { echo 'FAIL: run this block under bash — PIPESTATUS is a bash array and zsh expands it empty'; exit 2; }
_T0="$(timing_now_ms)"
TILLANDSIAS_SMOKE_LOCK_LOG=target/smoke-e2e/00-smoke-lock.log \
  scripts/with-smoke-lock.sh --name release-smoke-e2e -- \
  env TILLANDSIAS_NO_TRAY=1 tillandsias . --opencode --prompt "Use the /meta-orchestration skill" 2>&1 \
  | tee target/smoke-e2e/04-opencode.log
LANE_RC=${PIPESTATUS[0]}; printf 'opencode_exit=%s\n' "$LANE_RC" | tee target/smoke-e2e/04-opencode-exit.txt
timing_emit smoke-forge-lane smoke "$_T0" "${LANE_RC:-1}" || true
```

> The guard and the `LANE_RC` capture arrived with the timing wrapper
> (1013-qv7c). This block had neither: it piped to `tee` and recorded no status
> at all, so a forge lane that failed to launch left the same evidence as one
> that completed. Emitting a duration without an exit code would have recorded
> *how long the failure took* and called it a measurement, so the capture is
> part of the record, not scope creep — the 727-kmks assertion shape, arriving
> at the one step that never had it.

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
