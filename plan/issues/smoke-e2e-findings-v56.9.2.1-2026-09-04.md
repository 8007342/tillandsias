# Smoke e2e findings — release v56.9.2.1 — 2026-09-04 — esmeraldinha (windows floor)

- lane: windows / `windows-next`
- host: ESMERALDINHA — Intel N100, 4c/4t, 15.8 GB RAM, Win11 Home 26200, WSL 2.7.12.0 (kernel 6.18.33.2-2)
- release under test: `v56.9.2.1` (STABLE, non-prerelease; newest release at run time)
- installed build: `tillandsias-tray 56.9.2.1 (d6d3e3ed9)` — matches `origin/main` head
- sibling heads: main d6d3e3ed9 / linux-next 17ea51aaa / windows-next d45bbf9fc / osx-next 724691251
- preflight: `ok:cycle-preflight:rebuilt+expert-absent+wsl-ok+services-no-podman:skip:unsupported-host`
- **STATUS: LOCAL-ONLY, NOT PUSHED** — the host credential is dead (see Credential state), so this
  report could not be committed or pushed. macuahuitl-fedora files it.

## Credential state (blocks filing, not measuring)

`scripts/check-credential-channel.sh` → `ok:gh-credentials-store` (exit 0), yet `gh auth status` →
"The token in keyring is invalid", and `git push --dry-run origin windows-next` →
`remote: Invalid username or token`. The stored credential is a 40-char `gho_` OAuth token, not a
PAT; `GET /user` returns 401 so `github-authentication-token-expiration` is unreadable. There is no
PAT on this host to renew.

## PASS / FAIL table

| # | Step | Result | Evidence |
|---|---|---|---|
| 0 | Pre-flight, ledger row for the tag | PASS | `00-ledger-row.txt` — real per-release row at README.md:114 (not distilled) |
| 0 | Runbook §0.2b awk snippet runs | **FAIL** | fatal under GNU Awk 5.4.0 — F3 |
| 1 | Curl-install published artifact | PASS | `01-install-windows.log`; sha256 ok `b01b0b62…f84da` |
| 1 | Installed version == release tag | PASS | `01-version.txt` — `tillandsias-tray 56.9.2.1 (d6d3e3ed9)` |
| 2 | `wsl --terminate` + `--unregister tillandsias` | PASS | distro gone; `tillandsias-build` preserved (order 802-bajv honoured) |
| 2 | Download/state cache purge | PASS | `cache/ logs/ state/ wsl/` removed; `wsl-build/ext4.vhdx` (15.9 GB) preserved |
| 2 | Host vault credentials cleared (804-ckst) | PASS (runbook verifier FAIL) | store shows only `LegacyGeneric:target=tillandsias-vm-uuid` — F2 |
| 2 | `tillandsias-vm-uuid` preserved | PASS | present after reset |
| 3 | Cold `--provision-once` from pristine | PASS | exit 0, **117 s**, `03-provision.log` |
| 3 | Warm re-provision (idempotence) | PASS | exit 0, **18 s**, `03b-reprovision.log` |
| 3 | Wire Ready at provision exit | PASS | `--status-once` → reachable, wire_version 2, phase Ready, podman_ready true |
| 3 | **Ready state durable after provisioner exits** | **FAIL** | wire lost ~48 s idle, 3× reproduced — F1 |
| 5 | Final health check (last step) | **DEGRADED (exit 2)** | `05-final-diagnose.json` — `distro_running:false`, wire unreachable |
| 4 | Forge continuous-enhancement run | NOT RUN | skill scopes the `--opencode` forge lane to Linux/Podman; also credential-blocked |
| 4b | First-launch egress assertion | NOT APPLICABLE | podman-on-host assertion; Windows runs podman inside the guest |

**Note for the next reader on this lane, so you do not diagnose a hang that is not there:** mid-run
the provision looks wedged at package 99/145 for many minutes. It is not. The stdout tail is stale
buffered output, and the guest's `/proc/uptime` not advancing between checks is WSL2 idle-suspend —
i.e. finding 1 showing up early — not a stalled dnf transaction. Read `logs/tray.log` for the truth;
it records `provision-once: VM Ready` while the buffered tail still shows the dnf transaction.

Cold-provision cost on the floor, for the perf record: 117 s total — 66 MB rootfs download, OCI
flatten, a 145-package dnf transaction (113 install / 15 upgrade / 15 replace), guest start,
handshake. Warm re-provision 18 s. Per order 806-a4tu this lane is cold **by construction**.

## Ledger claims (README.md:114)

**EXERCISED**

- `--version` reports the workspace VERSION, not `0.1.0` (635-bhkb lineage): the installed tray
  answers `56.9.2.1 (d6d3e3ed9)`, asserted equal to the tag.
- Release assets publish and verify: SHA256SUMS-windows fetched, asset hash matched.
- Durable Windows launch-failure breadcrumb (665-zddn): `logs/launch-failure-diagnostics.json`
  present from the pre-reset install (8,633 bytes, captured to `02-pre-launch-failure-diagnostics.json`).

**NOT APPLICABLE (other platform / other lane)**

- dev-inference exit(2) pids ceiling (811-28eh), seven pids-limit sites at 4096 (959-fpc5) — Linux forge.
- litmus runner kill-time adjudicator / 36 hidden tests (956-llei), ghost-trace gate (867-vd4z),
  `build_check_mix` (890-nkdz), approved-UX-strings gate, capability-routing fixture — CI-gate lane.
- NVIDIA CDI classification (665-zddn second half) — no NVIDIA on this host.
- Lane socket listener / mcp-lane, 793-zumy Reachable/Placed producers — Linux enclave.

**NOT CHECKED (this lane could have and did not)**

- `803-49re` vault self-heal asking the key it just unsealed with — the exact defect the 804-ckst
  credential clear exists to expose. This run cleared the credentials correctly but never reached a
  GitHub login, so the re-auth path that broke the operator forty minutes in was not walked.
  **This is the biggest gap in the run** and it is squarely this lane's to close.
- `759-vceg` login flow checks authorization, not only authentication — same reason (no login reached).
- `805-r98w` hardware fingerprint refusing an untrue twin claim.
- `832-me6z` tray broadcast write bounded.
- `702-6jza D1` attach screen-home at the boundary.
- `797-thbw` debug-gated stderr echo.

---

### Work Packet: smoke-finding/windows-ready-not-durable-after-provision-once

- id: `smoke-finding/windows-ready-not-durable-after-provision-once`
- owner_host: windows
- capability_tags: [rust, windows, wsl, runtime, testing]
- status: ready
- discovered_by: `/smoke-curl-install-and-test-e2e` on release `v56.9.2.1`
- evidence:
  - `target/smoke-e2e/03-provision-exit.txt` — `provision_exit=0`, VM Ready, wire up
  - poll at 10 s interval immediately after a clean `--provision-once`:
    `t+8s reachable=true exit=0` → `t+48s reachable=false exit=1`
  - `target/smoke-e2e/05-final-diagnose.json` — `distro_running:false`,
    `wire.error: hvsocket open: AF_HYPERV connect to WSL VM (vsock 42420) failed: WSA_ERROR(10060)`,
    `exit_code: 2`
- repro:
  - `tillandsias-tray.exe --provision-once` (exits 0, "VM Ready — control wire up ✓")
  - wait ~60 s with no tray resident, then `tillandsias-tray.exe --status-once --json` → exit 1
- analysis: >
    `--provision-once` is documented to provision and exit, so nothing holds the guest open; WSL2's
    idle timeout then shuts the distro down and the vsock control wire dies with it. Reproduced three
    times. The consequence for THIS runbook is sharp: the skill mandates the health check as the last
    step after the last mutating step, and on Windows that check reads DEGRADED for a release that
    provisioned perfectly — the health check as written cannot express "Ready, then correctly idle".
    Two things need deciding and they are different: (a) whether a headless `--provision-once` should
    leave the guest resident or say plainly that Ready is momentary, and (b) whether `--diagnose`
    should distinguish "never came up" from "came up, then idled out" — today both are `exit 2` with
    `distro_running:false`, and only the log tail tells them apart.
- next_action: >
    Decide (b) first, it is cheap and it unblocks every future Windows smoke: give `--diagnose` a
    third state (or a `last_ready_ts` key) so an idled-out guest is not reported identically to one
    that failed to provision. Then revisit (a).
- events:
  - type: discovered
    ts: `2026-09-04T06:55:00Z`
    agent_id: `esme-windows`
    host: windows

### Work Packet: smoke-finding/804-ckst-credential-verifier-always-true

- id: `smoke-finding/804-ckst-credential-verifier-always-true`
- owner_host: windows
- capability_tags: [windows, testing, release, docs]
- status: ready
- discovered_by: `/smoke-curl-install-and-test-e2e` on release `v56.9.2.1`
- evidence:
  - runbook §2 predicate: `(& cmdkey.exe /list:$_ 2>$null) -match [regex]::Escape($_)`
  - measured, for a target just deleted AND for one that never existed:
    `cmdkey /list:<target>` prints `Currently stored credentials for <target>:` then `* NONE *`
  - the header echoes the queried name, so the `-match` is true unconditionally
  - ground truth from `cmdkey /list` (whole store) after the delete: only
    `Target: LegacyGeneric:target=tillandsias-vm-uuid` remains — the delete DID work
- repro:
  - `cmdkey.exe /list:definitely-not-a-real-target-xyz` → output contains the target name
- analysis: >
    Two failures from one bad predicate, in opposite directions. The post-delete assertion
    `if ($stillThere) { throw "host vault credentials survived the reset" }` fires on EVERY run,
    including a perfectly clean one — so §2 as written aborts the Windows smoke every time and the
    lane cannot complete. And the same predicate gates the delete itself, so the guard never guards.
    Order 804-ckst exists precisely because a stale share silently survived a reset and broke the
    operator forty minutes later; the step that closes it currently cannot report its own success.
    Same shape as `ok:gh-credentials-store`: a check whose green and its red are both unearned.
- next_action: >
    Replace both predicates with a whole-store read that matches the stored target line:
    `((& cmdkey.exe /list | Out-String) -match "target=$name")`. Verified correct against the ground
    truth above. Then re-run §2 on a Windows host and confirm it completes without throwing.
- events:
  - type: discovered
    ts: `2026-09-04T06:55:00Z`
    agent_id: `esme-windows`
    host: windows

### Work Packet: smoke-finding/ledger-row-awk-fatal-on-gawk

- id: `smoke-finding/ledger-row-awk-fatal-on-gawk`
- owner_host: any
- capability_tags: [testing, docs, windows]
- status: ready
- discovered_by: `/smoke-curl-install-and-test-e2e` on release `v56.9.2.1`
- evidence:
  - `awk: cmd. line:2: warning: escape sequence '\|' treated as plain '|'`
  - `awk: cmd. line:2: fatal: invalid regexp: unbalanced (: /^| v56.9.2.1( |()/`
  - GNU Awk 5.4.0 — the awk on Git Bash, and on most Linux hosts
- repro:
  - run the §0.2 or §0.2b block from `skills/smoke-curl-install-and-test-e2e/SKILL.md`
    with `SMOKE_TAG=v56.9.2.1` under gawk
- analysis: >
    gawk collapses `\|` and `\(` at string-parse time (with a warning) before the dynamic regex is
    built, so the intended `^\| v56.9.2.1( |\()` degrades to `^| v56.9.2.1( |()` — an unbalanced
    paren, which is fatal, not a warning. §0.2b is the step order 380 added so a run is aimed at what
    the release CLAIMS to have fixed; as written it kills the runbook on the way in. Worked around
    here with `grep -nE "^\| v56\.9\.2\.1( |\()" README.md`, which found the real row.
- next_action: >
    Build the regex without shell/awk double-escaping — pass the tag with `-v` and match with an
    index/substr test, or replace the block outright with the `grep -nE` form used here.
- events:
  - type: discovered
    ts: `2026-09-04T06:55:00Z`
    agent_id: `esme-windows`
    host: windows

### Work Packet: smoke-finding/windows-next-missing-stale-base-push-guard

- id: `smoke-finding/windows-next-missing-stale-base-push-guard`
- owner_host: any
- capability_tags: [git, hooks, testing]
- status: ready
- discovered_by: `/smoke-curl-install-and-test-e2e` preamble on `windows-next`
- evidence:
  - `scripts/install-hooks.sh` on `windows-next` installs `# tillandsias-pre-push-v7`
  - no `revert` guard text in the installed hook or in the installer on this branch
  - `git branch -r --contains 639df2537` → `origin/osx-next` only
- repro:
  - `git checkout windows-next && scripts/install-hooks.sh && head -2 .git/hooks/pre-push`
- analysis: >
    `639df2537 fix(1000-rqmx): refuse a push whose diff reverts files its commits never touched` has
    reached `osx-next` only. The incident that produced it was a Windows lane branch on a stale base
    whose diff would have deleted 5,096 lines of six other hosts' work — so the branch that most
    needs the guard is the one branch that does not have it. Not blocking today (this host cannot
    push at all), but it is live exposure for any Windows host whose credential is healthy.
- next_action: >
    Merge `origin/osx-next` (or cherry-pick 639df2537) into `linux-next`, then let the normal
    pre-push merge gate carry it to `windows-next`; confirm `install-hooks.sh` then reports v8.
- events:
  - type: discovered
    ts: `2026-09-04T06:55:00Z`
    agent_id: `esme-windows`
    host: windows

### Work Packet: smoke-finding/guest-pulls-full-multiarch-qemu-user-static

- id: `smoke-finding/guest-pulls-full-multiarch-qemu-user-static`
- owner_host: any
- capability_tags: [containers, performance, release]
- status: ready
- discovered_by: `/smoke-curl-install-and-test-e2e` on release `v56.9.2.1`
- evidence:
  - `target/smoke-e2e/03-provision.log` — 53 `qemu-user-static-*` lines in the guest dnf transaction,
    including `or1k`, `ppc`, `s390x`, `sh4`
  - transaction totals: 113 install / 15 upgrade / 15 replace = 145 packages
  - MEASURED 2026-09-04 on esmeraldinha, same run (`target/smoke-e2e/06-qemu-pkgs.txt`, rpm in the
    provisioned guest): 18 `qemu-user-static-*` packages, **170.6 MB installed**, of which
    `qemu-user-static-x86` is **9.7 MB** — an x86_64-only set saves **161.0 MB (94.3%)**.
    Largest foreign arches: mips 32.9, ppc 16.1, aarch64 16.0, xtensa 15.4, sparc 13.7,
    riscv 11.7, arm 11.4 MB. (The "53 lines" above counts LOG LINES — download, install and
    progress redraws — not packages; 18 is the package count a reader should act on.)
  - MEASURED download cost, parsed from `03-provision.log`: qemu-user-static **35.7 MB / 8 s**
    against a whole-transaction **233.2 MB / 39 s** — **15.3% of bytes, 20.5% of download time**.
  - Install-phase time is NOT resolvable: all 18 qemu install lines report `00m00s` against the
    log's 1 s resolution, so the supportable bound is "below 1 s each, ≤18 s worst case", not a
    measured zero.
- repro:
  - `tillandsias-tray.exe --provision-once` from a pristine state; grep the log for `qemu-user-static`
  - `wsl -d tillandsias -- rpm -qa --qf "%{NAME} %{SIZE}\n" | grep ^qemu-user-static`
- analysis: >
    Every cold provision pulls the complete cross-architecture emulation set as a transitive
    dependency of the podman/systemd install, on a lane that is cold BY CONSTRUCTION (order 806-a4tu)
    and therefore pays it every single run. Floor-tier cost, and worse on a metered or slow link.
    Scoping the dependency to the host architecture is the obvious lever.
    SIZED, and the honest reading of the numbers: against the 117 s cold provision, dropping the
    foreign arches buys **~8 s of wall clock, ~36 MB of transfer, and 161 MB of guest disk**. The
    seconds are not the argument — the 66 MB rootfs and the 145-package transaction dominate, and
    this host is on a fast link. The two claims that travel are the TRANSFER, which bites on a
    metered or slow link and is paid on every single run of a lane that is cold by construction, and
    the DISK: 94.3% of an installed emulation set that nothing on an x86_64 fleet can use. Priority
    should follow the 36 MB, not the 94% headline, which is about disk rather than time.
- next_action: >
    Check FIRST whether `qemu-user-static` is arriving as the meta-package — it is installed here at
    28 KB, which is the signature of exactly that — because if so the arches come in through the
    dependency solver and a recipe-line exclusion will fight it rather than fix it. Then decide
    between an explicit `qemu-user-static-x86` pin and a solver exclusion, and re-measure a cold
    provision to confirm the 36 MB / 8 s actually disappears.
- events:
  - type: discovered
    ts: `2026-09-04T06:55:00Z`
    agent_id: `esme-windows`
    host: windows

### Work Packet: smoke-finding/windows-runbook-has-no-step-3-block

- id: `smoke-finding/windows-runbook-has-no-step-3-block`
- owner_host: any
- capability_tags: [docs, testing, windows]
- status: ready
- discovered_by: `/smoke-curl-install-and-test-e2e` on release `v56.9.2.1`
- evidence:
  - SKILL.md §3 has a Linux block and a macOS block; the Host Matrix promises Windows
    "installed tray provision/diagnose" and no Windows block exists
  - the macOS block's flag is `--provision`; the Windows tray's flag is `--provision-once`
    (`tillandsias-tray.exe --help`), so the nearest block is not copyable
  - §1's Windows install snippet also has no `PIPESTATUS`/exit-code equivalent — the gap order
    727-kmks closed for Linux and 2026-08-26 closed for macOS
- repro:
  - read `skills/smoke-curl-install-and-test-e2e/SKILL.md` §3 looking for the Windows lane
- analysis: >
    Same shape as the macOS gap closed on 2026-08-26: the matrix promises a lane the runbook does not
    make executable, so each Windows run improvises and the runs are not comparable to each other.
    This run improvised `--provision-once` → `--status-once --json` → `--diagnose --json`, using the
    forced-wait pattern the tray's own `--help` prescribes for its GUI-subsystem binary.
- next_action: >
    Add the Windows §3 block with the sequence this run used, with asserted exit codes, and carry the
    727-kmks exit-code assertions into the §1 Windows install snippet.
- events:
  - type: discovered
    ts: `2026-09-04T06:55:00Z`
    agent_id: `esme-windows`
    host: windows
