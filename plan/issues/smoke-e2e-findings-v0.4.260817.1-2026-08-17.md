# Published-release curl-install e2e — v0.4.260817.1 on Windows — findings 2026-08-17

discovered_by: `/smoke-curl-install-and-test-e2e` (windows), driven by the
meta-orchestration cycle windows-yolanda-opus5-20260817t1757z.
Host: **Yolanda** (windows), branch `windows-next`, channel **daily**,
resolved `channel:daily tag:v0.4.260817.1`.
Evidence: `target/smoke-e2e/` (host-local).

This is the first curl-install e2e of the release cut on linux-mutable at
2026-08-17T12:43Z. Step 4 (the `--opencode` forge lane) is not run on Windows —
that lane is Linux/Podman per the skill's §0.1.

## Run 2026-08-17T17:58Z→18:06Z — **PASS** (tag v0.4.260817.1, build commit 0bba6525f)

- **Step 1 curl-install**: `install-windows.ps1` fetched from the pinned release
  base with `TILLANDSIAS_VERSION=v0.4.260817.1`. SHA-256 verified against the
  published `SHA256SUMS-windows`
  (`4c83f8de60a2fc6f75b0b274303774ff093f8ba355da6fabcbfe15daccac9ded`), extracted
  to `%LOCALAPPDATA%\Programs\Tillandsias`, Start Menu shortcut written,
  registered in Installed Software. `install_exit=0`.
  **Version assertion PASS** — `tillandsias-tray 0.4.260817.1 (0bba6525f)`
  contains the resolved tag, so the artifact under test is provably the
  published one (order 727-kmks's assertion, not a comment).
- **Step 2 destructive reset**: tray stopped, `wsl --terminate tillandsias` +
  `wsl --unregister tillandsias` (exit 0), then purged
  `%LOCALAPPDATA%\tillandsias\{wsl,cache\rootfs,state}` — including the 34.9 GB
  `ext4.vhdx` and the cached `fedora-44-wsl-75200f5752a7` rootfs. This was
  described here as a **truly cold** run — **that claim is CORRECTED below
  (see "Correction"): the host-side Windows Credential Manager entries survived,
  and they turned out to matter.** `tillandsias-build` (this host's
  Linux-artifact lane, Running at the time) was left untouched — see
  finding `smoke-finding/windows-substrate-reset-uses-global-wsl-shutdown`.
- **Step 3 cold provision**: `--provision-once` exit **0** in **67 s** from the
  wiped substrate — rootfs re-downloaded, distro re-imported, a 143-package dnf
  transaction (111 installed / 15 upgraded / 15 replaced), `podman.socket` +
  the three `tillandsias-headless*` units enabled, guest root headroom 954 GiB,
  `VM handshake success (phase=Ready) wire_version=2 attempt=1`,
  `RESULT: VM Ready — control wire up ✓`.
- **Post-condition after the last MUTATING step** (2026-08-10's rule): the last
  mutating step was the tray GUI launch, not the provision. Fresh
  `--diagnose --json` exit **0 = HEALTHY**: distro registered **and running**,
  wire reachable, `phase=Ready`, `podman_ready=true`, no error,
  `guest_version 0.4.260817.1 == tray 0.4.260817.1`, guest_wiring
  `skipped-version-match` (no embed-vs-fetch skew). `--status-once --json`
  exit 0, `reachable=true`.
- **Step 4 forge lane**: n/a on Windows (Linux/Podman lane per skill §0.1).

**Verdict: the published v0.4.260817.1 Windows artifact bootstraps the whole
enclave from nothing, unattended, in 67 s, and lands HEALTHY.**

### Interval note (not a defect): Ready-then-idle between processes

Between Step 3 and the tray launch, a `--diagnose` taken in a *separate* process
read `distro_running=false` / wire `WSA_ERROR(10060)` / exit 2 (degraded).
`--provision-once` is documented to reach Ready and exit, and nothing then holds
the utility VM up, so WSL idles it down. Launching the tray returned it to
`phase=Ready podman_ready=true` on the **first** poll. This is the documented
contract behaving as written, not a regression — but it is a live trap for any
automation that provisions in one process and health-checks in another, and it
is why the PASS above is anchored on a post-tray-launch check. Filed as a
runbook clarity packet below rather than a product defect.

---

### Work Packet: smoke-finding/tray-help-prescribes-the-one-capture-pattern-that-silently-fails

- id: `smoke-finding/tray-help-prescribes-the-one-capture-pattern-that-silently-fails`
- owner_host: windows
- capability_tags: [windows, tray, rust, docs, testing]
- status: ready
- discovered_by: `/smoke-curl-install-and-test-e2e` on release `v0.4.260817.1`
- trace: `crates/tillandsias-windows-tray/src/notify_icon.rs:813-818`
  (`OUTPUT NOTE:` block), pinned by `help_text_documents_all_cli_modes`
  (`notify_icon.rs:4745`)

**Symptom.** The shipped `--help` tells support scripts to do the one thing that
returns neither output nor an exit code, and to distrust the thing that works.
Verbatim from the released binary:

> The tray is a GUI-subsystem binary; PowerShell pipe capture of stdout
> is unreliable (Rust treats a detached stdout as BrokenPipe and discards).
> Support scripts MUST redirect to a file: `tillandsias-tray.exe --diagnose --json > out.json 2>nul`
> and branch on the exit code rather than the captured output.

Measured on the installed v0.4.260817.1 binary, four probes, same host, same
minute:

| # | Pattern | `$LASTEXITCODE` | Captured |
|---|---|---|---|
| A | `& $exe --diagnose --json > out.json 2>$null` — **the prescribed pattern, in PowerShell** | **empty** | **0 bytes** |
| B | `& $exe --diagnose --json \| Out-String` — the pattern the note calls unreliable | `0` | 2848 chars, valid JSON |
| C | `Start-Process -Wait -PassThru -RedirectStandardOutput` | `0` | 42 bytes (`--version`) |
| D | `& cmd.exe /c "$exe --diagnose --json > out.json 2>nul"` | `0` | 42 bytes (`--version`) |

**Root cause.** The binary is linked GUI-subsystem, so PowerShell does not wait
on it. A pipeline *incidentally* forces a wait (PowerShell must read to EOF),
which is why B works. A bare file redirect does not, so PowerShell returns
before the child writes anything and never records an exit status. The note's
guidance is sound **only under `cmd.exe`** — which is what `2>nul` (cmd syntax,
not PowerShell's `2>$null`) silently assumes, while the note's own first
sentence names PowerShell.

**Why this matters.** The failure is silent and reads as healthy-shaped: a
support script gets an empty file and a null exit code. The entire Windows lane
— installer, diagnostics, smoke — is PowerShell. This smoke ran the prescribed
pattern first and recorded a provision that *never executed* (`provision_exit=`,
`provision_seconds=0`, 0-byte log) before the discrepancy was caught.

**The knowledge already exists in-tree and did not reach the operator.**
`scripts/tray-diagnose.ps1:81-86` — "the canonical PowerShell consumer" —
carries the correct comment and wraps in `cmd.exe /c`. The help text, which is
what an operator actually reads, does not mention the wrapper.
`help_text_documents_all_cli_modes` asserts the `OUTPUT NOTE:` header is
*present*; nothing asserts it is *correct*, so a pinned-but-wrong note is
indistinguishable from a pinned-and-right one.

- evidence:
  - `target/smoke-e2e/03-provision-exit.txt` — first attempt: `provision_exit=` (empty), `provision_seconds=0`
  - `target/smoke-e2e/03-provision.log` — 0 bytes on that attempt; the distro was never created
  - probes A–D above, re-runnable from the packet body
- repro:
  - `& "$env:LOCALAPPDATA\Programs\Tillandsias\tillandsias-tray.exe" --version > out.txt 2>$null; $LASTEXITCODE; (Get-Item out.txt).Length`
  - → empty exit code, 0 bytes
- next_action: >
    Correct the `OUTPUT NOTE:` in `notify_icon.rs` to name the wrapper the
    working patterns need (`cmd.exe /c "... > file 2>nul"`, or
    `Start-Process -Wait -PassThru -RedirectStandardOutput`) and stop asserting
    that pipeline capture is unreliable without qualifying it — measurement B
    contradicts that for both small and 2.8 KB outputs. Then strengthen
    `help_text_documents_all_cli_modes` so it pins the note's *content*
    (the wrapper token) and not merely its header, since the header assertion is
    what let an incorrect note ship pinned.
- events:
  - type: discovered
    ts: `2026-08-17T18:02:00Z`
    agent_id: `windows-yolanda-opus5-20260817t1757z`
    host: windows

**Related but distinct** (do not merge):
`plan/issues/optimization/install-windows-local-exit-code-leak-2026-07-12.md` is
a *build* script leaking a real exit code 2 as its own. This packet is a
*shipped help text* prescribing a pattern under which no exit code exists at
all.

---

### Work Packet: smoke-finding/windows-substrate-reset-uses-global-wsl-shutdown

- id: `smoke-finding/windows-substrate-reset-uses-global-wsl-shutdown`
- owner_host: windows
- capability_tags: [windows, testing, docs]
- status: ready
- discovered_by: `/smoke-curl-install-and-test-e2e` on release `v0.4.260817.1`
- trace: `skills/smoke-curl-install-and-test-e2e/SKILL.md` §2 (Windows lane) and
  the Host Matrix row

**Symptom.** The Windows destructive-reset step reads "run `wsl --shutdown` and
`wsl --unregister tillandsias`". `wsl --shutdown` stops **every** WSL2 distro on
the host, not just the one under test. On this host `tillandsias-build` — the
lane that builds Linux-target artifacts — was **Running** at reset time, and on
any host where a build or a sibling agent is mid-flight, the smoke silently
takes it down as collateral.

`wsl --terminate tillandsias` is the targeted equivalent and is sufficient:
`--unregister` only requires the target distro to be stopped. This run used the
targeted form and Step 2 passed unchanged.

- evidence:
  - `target/smoke-e2e/02-reset.log` — `wsl --terminate tillandsias` then
    `wsl --unregister tillandsias`, both "operation completed successfully",
    `unregister_exit=0`
  - post-reset `wsl -l -v`: `tillandsias` absent, `tillandsias-build` still Running
  - prior runs handled this by unwritten judgment, not by the runbook:
    `plan/issues/build-install-smoke-e2e-findings-2026-08-16-windows.md:18-19`
    records "`tillandsias-build` untouched" while the skill still prescribed the
    global form
- repro:
  - on a host with a second WSL2 distro running, follow the skill's Windows §2 verbatim
- next_action: >
    Change the Windows lane in both e2e skills from `wsl --shutdown` to
    `wsl --terminate tillandsias`, and say why in one clause (a smoke must not
    disturb host state outside the artifact under test). Check the sibling
    runbook `skills/build-install-and-smoke-test-e2e/` for the same wording.
- events:
  - type: discovered
    ts: `2026-08-17T18:00:00Z`
    agent_id: `windows-yolanda-opus5-20260817t1757z`
    host: windows

---

### Work Packet: smoke-finding/windows-e2e-lane-underspecifies-provision-then-diagnose

- id: `smoke-finding/windows-e2e-lane-underspecifies-provision-then-diagnose`
- owner_host: windows
- capability_tags: [windows, testing, docs]
- status: ready
- discovered_by: `/smoke-curl-install-and-test-e2e` on release `v0.4.260817.1`
- trace: `skills/smoke-curl-install-and-test-e2e/SKILL.md` Host Matrix, Windows
  row: "installed tray provision/diagnose"

**Symptom.** The Windows re-provision cell is four words and omits the step that
decides the verdict. `--provision-once` reaches Ready and exits; WSL then idles
the utility VM down; a `--diagnose` run in a separate process therefore reports
`distro_running=false`, wire `WSA_ERROR(10060)`, exit 2 (degraded) — on a
release that is in fact healthy. A smoke following the cell literally would
record a **false FAIL** against a good artifact.

The tray must be launched (or the distro otherwise held up) between provision
and the health check. Once launched, this run read `phase=Ready
podman_ready=true` on the first poll and `--diagnose` exit 0.

- evidence:
  - `target/smoke-e2e/05-status.json` (pre-tray-launch) — `reachable:false`,
    `error: "control wire unreachable on vsock 42420 ... WSA_ERROR(10060)"`, exit 1
  - `target/smoke-e2e/05-diagnose.json` (post-tray-launch) — exit 0, phase Ready,
    podman_ready true
- repro:
  - `tillandsias-tray.exe --provision-once` (exit 0), wait for WSL idle-down, then
    `tillandsias-tray.exe --diagnose --json` in a new process → exit 2
- next_action: >
    Spell the Windows lane out as an ordered sequence — provision → launch tray →
    poll `--status-once` to Ready → `--diagnose --json` as the post-condition —
    and state that the health check must follow the tray launch because that is
    the last mutating step. Consider whether `--provision-once`'s help should
    note that the VM does not stay up after it exits.
- events:
  - type: discovered
    ts: `2026-08-17T18:04:00Z`
    agent_id: `windows-yolanda-opus5-20260817t1757z`
    host: windows

---

## Correction, 2026-08-17T19:00Z — the run was NOT a clean room, and the release DOES have a release-grade defect

Filed after the operator clicked "GitHub login" on this very install ~40 minutes
after the PASS above was recorded, and it failed. Packets: **803-49re** (p1,
product) and **804-ckst** (p2, these runbooks).

**The PASS verdict stands for what it measured** — install, substrate reset,
cold provision and post-condition health were all genuinely green, and remain
so. What was wrong is the *scope* claim attached to Step 2.

**What I got wrong.** Step 2 called the run "truly cold" on the strength of
purging the 34.9 GB `ext4.vhdx` and the rootfs cache. Both were purged; neither
is the whole substrate. The Windows tray treats **Windows Credential Manager**
as the authoritative source for the Vault unseal share
(`installation_uuid.rs:155-171`), and nothing in the product, the installer's
`-Purge`, `--reset-guest`, or this runbook ever clears it. So the "clean room"
silently carried the previous install's vault identity forward.

**Why that produced a false green.** The smoke's own post-condition
(`--diagnose` exit 0) is honest and still passes: Vault unseals fine, because
the guest's *podman secret* holds the correct key. The stale host share only
bites on the first operation that needs `generate-root` — which is the first
real thing an operator does. So the release looked healthy to the gate and
broke on first use. A post-condition after the last mutating step was not
enough here; the failure needed the first *user* action, which no step of this
runbook performs.

**This is the keychain↔volume resync brick the skill's own §2 warns about**
("if init bricks, that is a finding, not a failure to hide"). It did brick. The
warning names the macOS keychain and Linux Vault volume; the Windows equivalent
was not covered, and the Windows lane is where it fired.

**Amendment to Step 2 for future Windows runs** — clear the host credential
store as part of the destructive reset, preserving the installation UUID:

```powershell
cmdkey /delete:vault-shamir-share-v1
cmdkey /delete:vault-root-token-v1
# do NOT delete tillandsias-vm-uuid — that is the installation identity
```

Do **not** try to repair these with `cmdkey` write: `read_credential_string`
parses the blob as UTF-8 and `cmdkey` stores UTF-16.

**Recovery applied on this host** (non-destructive; vault storage untouched,
exactly as the product's error text demanded): stop tray → delete the two stale
credentials → rewrite the guest fallback share from the podman secret → relaunch
tray. Verified after: share survives a tray restart, Credential Manager
re-populated from the guest, `root generation finished` replacing `aborted`,
cached root token authenticates (`display_name=root`), zero aborts in 90 s.
