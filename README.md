```text
  ____________    __    ___    _   ______  _____ _______   _____
 /_  __/  _/ /   / /   /   |  / | / / __ \/ ___//  _/   | / ___/
  / /  / // /   / /   / /| | /  |/ / / / /\__ \ / // /| | \__ \
 / / _/ // /___/ /___/ ___ |/ /|  / /_/ /___/ // // ___ |___/ /
/_/ /___/_____/_____/_/  |_/_/ |_/_____//____/___/_/  |_/____/
```

The Tlatoāni recommends Tillandsias as a safe runtime for your agents.
Fedora Silverblue is our favorite OS but you can use whatever you want;
we'll channel its inner Podman ;)

## Install

Everything below tracks the **stable channel** — the latest *promoted*
release. For the newest daily build, see
[Unstable Releases](#unstable-releases).

**Linux** — curl installer (we prefer Fedora Silverblue):

```bash
curl -fsSL https://github.com/8007342/tillandsias/releases/latest/download/install.sh | bash
```

**Windows** — portable download: **[tillandsias-tray.exe](https://github.com/8007342/tillandsias/releases/latest/download/tillandsias-tray.exe)** (single file) or **[tillandsias-windows-x64.zip](https://github.com/8007342/tillandsias/releases/latest/download/tillandsias-windows-x64.zip)** (zip). Run it; the tray provisions a Fedora WSL2 distro automatically.

**macOS** — portable download: **[Tillandsias.dmg](https://github.com/8007342/tillandsias/releases/latest/download/Tillandsias.dmg)** (Apple Silicon). Open it and drag Tillandsias into Applications; the tray provisions a Fedora VM automatically.

Podman is the only host dependency on Linux (auto-detected). macOS and Windows
provision a lightweight Fedora-based utility VM; no host Podman required.

<a id="unstable-releases"></a>

<details>
<summary><b>Unstable Releases</b> — curl-install the newest daily build (Linux, Windows, macOS)</summary>

The **unstable channel** is a rolling pointer at the newest daily build,
whether or not it has been promoted to stable. It exists so we — and opt-in
testers — can exercise a real build on real hosts *before* promotion. The URLs
never change; the build behind them moves with every daily.

**Expect breakage.** These builds have passed the local release gate but not
the cross-platform smoke queue that gates promotion. Every installer prints an
`UNSTABLE` banner before it touches your machine. If one breaks, that is the
channel doing its job — file it in `plan/issues/`.

Linux:

```bash
curl -fsSL https://github.com/8007342/tillandsias/releases/download/unstable/install.sh | bash -s -- --channel unstable
```

macOS:

```bash
curl -fsSL https://github.com/8007342/tillandsias/releases/download/unstable/install-macos.sh | bash -s -- --channel unstable
```

Windows (PowerShell):

```powershell
$env:TILLANDSIAS_CHANNEL='unstable'; irm https://github.com/8007342/tillandsias/releases/download/unstable/install-windows.ps1 | iex
```

Browse the artifacts directly at the
[unstable release](https://github.com/8007342/tillandsias/releases/tag/unstable).

**Promotion to stable.** A daily becomes the stable channel only when a release
operator runs `scripts/promote-stable.sh vX.Y.YYMMDD.N`, which requires
curl-install e2e PASS evidence in `plan/` naming that exact tag. Promotion flips
the release off pre-release, which is what moves `/releases/latest` — and
therefore every stable command above. Demote with
`gh release edit <tag> --prerelease`.

</details>

## RELEASE LEDGER

For humans and agents alike: what each release set out to do, what it
actually shipped, and what broke and got fixed along the way. Agents doing
smoke curl-installs or jumpstarting work read the recent rows first; rows
age into semantic distillation (detail lives with the most recent releases;
see `plan/issues/` for the full evidence trail of any row).
The release skill appends a row per release; STABLE marks channel promotions.

<details>
<summary>Release ledger (newest first)</summary>

| RELEASE | INTENDED FEATURES | BUGFIXES |
|---|---|---|
| v0.4.260810.1 (daily) | A LEDGER-INTEGRITY AND TRIAGE wave — almost all of it found by hosts reviewing each other rather than by reading code. **635-i6vm**: 11 of 21 fragment-recorded completions were being silently discarded by the G-Set fold, so finished work stayed claimable — the mechanical root of agents rediscovering done work. **641-e2qa**: 21 packets stranded in `in_progress` with no event ever recorded, 8 of them claims abandoned 17–26 days; a reclaimer now returns those to `ready` (it never auto-closes — reclaiming destroys nothing, closing on a guess destroys the work). **636-9m79**: `tillandsias-plan set-field` ends hand-authored ledger writes and reaches fragment-only packets, closing 600-c266. **632-39p3**: `--claimable-by` — `query --role` excluded `pickup_role: any`, so Windows cycles were handed ONE packet while 56 `any` packets sat unreachable; macOS 13→52, Windows 7→48 eligible. Also the cycle-batch triage selector (minimax-ranked, budgeted, entropy-floored) and the rolling UNSTABLE channel, now confirmed on all three platforms. | The root cause of the ledger corruption turned out to be **our own instructions**: `advance-work-from-plan` step 7 documented BOTH broken close paths (`append-event`, blind to fragment-only packets, and a fragment re-declaration, a G-Set no-op) — three hosts followed it correctly and all three lost completions. **638-ehzi**: the intermittent `--ci-full` failure dismissed twice as unexplained was two parallel tests racing on `$HOME` and a shared fixture dir; 0 failures in 8 runs after, ~1-in-4 before, and the evidence had been sitting in `check-logs.jsonl` the whole time. **619-pfsj slice**: `project_answer` never satisfied the envelope contract it claimed — five violations, `verify-answer` refused every envelope it produced — now clean on all three fixtures. Four expression-pinned litmus guards repaired (634-39ik escalated for a ruling). Sibling fixes: macOS 627-53gu/628-yd8f/492 plus a 5/5-PASS 624-q4jj validation discharging the order-455 macOS smoke; Windows 632-retq/635-qpx8/640-iujb/643-bnag — five of which were defects in Linux-authored code. |
| v0.4.260809.2 (**STABLE** — promoted 2026-08-09 by operator directive via `promote-stable --force`; the order-455 curl-install e2e is still owed for this tag, so the basis is artifact verification plus three green platform jobs, recorded in `plan/issues/stable-promotion-v0.4.260809.2-2026-08-09.md`) | Same feature set as v0.4.260809.1 — the rolling UNSTABLE channel, the three-installer landing page, and the version-stable Windows portable aliases — cut again so the stable channel could serve them. Promotion was the point: `/releases/latest/download/tillandsias-tray.exe` and `tillandsias-windows-x64.zip` 404 against every release predating the aliases, so the landing page's Windows links could not work until a release carrying them became Latest. All six advertised stable links now resolve. | Carries 623-iwq4, which is why this build exists rather than promoting .1: `SHA256SUMS-windows` is now newline-normalized before the alias checksums are appended, and the job runs `sha256sum -c` on it *before* signing, so a checksum file that cannot verify fails the release instead of shipping signed. Verified against the published artifacts — all three Windows entries OK, alias hash identical to the versioned zip, Linux binary reports `v0.4.260809.2`, DMG checksum OK. |
| v0.4.260809.1 (daily) | The **release-channel split** this page now advertises (621-2re2, operator directive): a rolling UNSTABLE channel so we — and later opt-in users — can run the newest build on real hosts *before* promotion. `unstable` is a GitHub prerelease that the Linux job DELETES and recreates every daily and the macOS/Windows jobs refill from the SAME run; recreate-not-clobber is deliberate, since clobbering in place strands a stale platform asset whenever a platform job fails and the channel then serves a mismatched artifact set that still reads as current. First run published all three platforms into it. All three installers gained channel selection (`--channel`, `TILLANDSIAS_CHANNEL`) and print an UNSTABLE banner; `TILLANDSIAS_RELEASE_BASE` still overrides so the smoke keeps pinning one exact release. Windows gained version-stable portable aliases (`tillandsias-windows-x64.zip`, `tillandsias-tray.exe`) because the packaged zip carries the version in its NAME and could never be linked from `/releases/latest/download`. Landing page cut to three primary installers plus the collapsible Unstable Releases section. Also carries the windows-next low-end host fixes (620-9xpg wt.exe title quoting, 620-ujyc/ca7g/cine adopt-path guest reconciliation, WSL in-VM marker, inference gate, login wrapper). | **This release's Windows `SHA256SUMS-windows` is corrupt — do not trust it** (623-iwq4, fixed for the next daily): the packaging script writes the file with no trailing newline, so appending the alias checksums merged the first new entry into the last existing one, destroying a pre-existing versioned-zip entry that had verified in every prior release. It shipped Cosign-signed because nothing verified the sums file before signing it; the fix normalizes the newline *and* runs `sha256sum -c` pre-publish so the job fails instead. Found by verifying published artifacts, not by reading code. Also: three litmus guards were false-red (622-rmit) — each pinned a literal source expression, so property-preserving refactors from 619-vwau and 621-2re2 broke them; two had been red on `linux-next` since 2026-08-08 and cost a cycle to prove pre-existing. All three rewritten to assert properties, with a new `scripts/check-installer-channel.sh` that executes an installer's own channel resolution under a falsifiable grammar. |
| v0.4.260804.1 (daily) | First release gated ENTIRELY on local hardware — push CI was removed 2026-08-03 (only the release may spend cloud minutes), so `./build.sh --ci-full` (17/17 checks, 237/237 litmus) plus `scripts/release-preflight.sh` is now the whole gate, enforced by a stamped pre-push hook and a config-driven CI-workflow allowlist at the git mirror (599-w5jd). Carries both sibling hosts' v0.5 validation bundles: Windows 598-yhu5 (six verdicts, staging defect fixed) and macOS 598-kibt (8 accel_probe lints Linux could not enumerate, 11 macos-tray lints, `cloud_projects_loaded` wired for the empty-repo submenu, 13-failure litmus truth sweep). Tray-parity required rows: 0 gaps on all three platforms. Also: first real CRDT ledger compaction (28 fragments folded, 120 comments preserved, zero base lines removed), GitHub token gone from every forge lane, brew attestation off with Sigstore egress allowlisted. | Four defects found by RUNNING this release, none visible from reading the code: `litmus:local-ci-self-clean-evidence` was unsatisfiable because the convergence dashboard rewrote its own wall-clock stamp every run, so `--ci-full` failed on dirt it had just created; `--ci-full` did not write the gate stamp while `--check` did, so passing 17 checks left you less able to push than passing 6 (602-68gf); the VERSION guard and the release preflight deadlocked — the preflight requires linux-next to carry main's post-release VERSION, the guard refused any commit touching it there, exit only via `--no-verify` at the release (602-tfzg); and the release skill still said "wait for CI" when `gh pr checks --watch` exits 0 on "no checks reported", so it would have merged unverified while reading as a passing gate (601-f6ci). Plus the gate-stamp symlink bug macOS caught: suppressed stderr hid "Is a directory" for all 45 tracked directory symlinks, so the stamp silently validated a tree with 45 entries missing. |
| v0.4.260728.2 (**STABLE** — promoted 2026-07-28 by operator directive via promote-stable --force: attended Windows local-build validation of the identical source (89059357 — fresh provision, GitHub login flow PASS, OpenCode forge launch + in-forge test/push PASS); published-artifact curl-install e2e still owed to the order-455 queue) | Windows login-gate recovery release: generate-root self-heal now iterates ALL Shamir-share candidates (host-delivered → host keychain → guest fallback file, deduped) and persists the winning share — kills the stale-host-share MAC-failure wedge that kept the v0.4.260728.1 Windows tray permanently login-gated; cloud-projects submenu gains a "(loading repos…)" state distinct from confirmed-empty (operator-approved UX); guest-binary staging refreshed so the embedded guest matches the release version. Also carries same-day linux-next work: github-login UX ordering (token before git identity), forge new-container smoke + order-147 progress, order 392a/b split, git-mirror branch-scheme rung 2. | Windows v0.4.260728.1 field-regression audit (plan/issues/windows-v04-login-gate-vault-epoch-skew-2026-07-28.md): release install reused a stale v0.3.260724.1 guest (no upgrade path — release-lane packet owed), old guest wiped vault-data on nearly every boot (token never persisted), resident service wedged on a stale host-delivered share while login consoles succeeded; rustfmt gate fix. |
| v0.4.260728.1 (**STABLE** — v0.4 series opener; promoted 2026-07-28 after same-day Linux curl-install e2e PASS) | The v0.4 stability-bundle promotion (series bump 0.3 → 0.4, operator-directed): full three-branch convergence into one release — osx-next terminal-attach@v2 (in-window attach client, PTY backpressure, TERM/COLORTERM forwarding, macOS destructive e2e PASS 5a44fd69) + windows-next v0.3.260724.1 smoke PASS + main back-merge; 15-packet adversarial release triage with ZERO blockers (plan/issues/v04-release-triage-2026-07-27.md); charter met: no crashloop / no work loss / no forge-mirror corruption + qualifying macOS & Windows smoke PASS. Post-release: 455 cross-platform smoke queue activates against THIS build. | Order-462 dual-fix reconciliation (find_diff_base + legacy-archive exemption kept over main's inline merge-base); 494 interim leak-not-destroy guard (cleanup can no longer force-remove a RUNNING sibling forge — non-force rm, shared stack survives the zero-lane misread); 465 closed (host-mount escape hatch now loud + Once-gated); 486 inference cold-start (CA bundle + bounded egress-gated backoff); 476(b) committable-branch guard + litmus; 448 cheatsheet-tree recurrence; 495 filed (preflight evidence dirt defeats its own forge gate). |
| v0.3.260724.1 (daily, PRE) | First daily carrying the full 07-23/24 stability wave: git-mirror Vault Agent auto-auth (48h relay survives token max-TTL without restart, order 424 slice), codex worker state persistence + digest-stable instance identity (ends the 281s first-run replay), WSL probe timeouts non-destructive (one bounded recovery, damage requires proof), OpenCode credential-free vault auth (431), delegated-result channel authoritative capture (429 slice), diagnostics no-spill closure (453) | Squid fail-closed cache policy (DONT_VERIFY_PEER removed — bumped traffic now verifies origin; single release-asset CDN bump target); harness warm-launch byte-cheap + cold-miss download lock; order 463 soak fixes staged (enclave-URL vault endpoint in-VM); ledger: dup-462 renumber, 465-477 filed |
| v0.3.260723.1 (daily, PRE) | The order-455 PASS-candidate (first published build >= 58b58322, cut on the Windows lane's coordinator ask): Windows v0.4 lane CODE-COMPLETE — WSL-absent runtime as a first-class state with curated background `wsl --install` (windows-260722-1), app identity + single Installed-Software entry (windows-260722-3), headless --github-login CA-bundle mount, curated connection chips; first complete live Windows full-stack chain (host tray -> WSL2 -> podman -> forge -> in-forge opencode meta-orchestration) validated at ~5% infra overhead | Two P1s from the 455 smoke: shipped .ps1 saved-then-run parsed into a DIFFERENT program (BOM-less UTF-8 em-dash -> CP-1252 smart quote; all .ps1 pure-ASCII + whole-file litmus) and rootfs download quantized to ~40 KB/s by the 100ms GUI-pump executor (4 MiB BufWriter + dedicated bg runtime; A/B 25min-DNF -> 2.9s, wipe-to-VM-ready 72s); 313 SOLVED (root-owned models-mount EACCES, not proxy warm-up); mirror readiness gate waits for SEEDED not merely reachable; forge-HOME/container-HOME test collision |
| v0.3.260722.1 (daily, PRE) | v0.4 stability-bundle candidate for the order-455 cross-platform smokes: 3 drain waves (9 packets — vault unseal gates, guest crashloop detection on all platforms, 3-state login, ephemeral guest reset via CLI, 443 shared-stack refcount COMPLETE), UX curation governance (Tlatoani-gated, tray-ux spec) with the unapproved reset-guest leaf removed, order-459 official curl-install harness channel | first release PR gated by real CI (fmt/workspace + NEW windows/macos cfg-typecheck lanes — caught 4 latent type errors on maiden run); review hardening: podman-ps failure now leak-not-destroy; 313 CA/path pins; stale-ledger flips (281) |
| v0.3.260721.1 (daily, PRE) | v0.4 stabilization pre-release for cross-platform curl-install smoke (order 455): committed bootstrap for all harnesses (AGENTS.md + skills-farm repair), ./repeat --model delegation passthrough, coordinator triage tightening v0.4 to the Linux stability bundle | order 454 mirror unborn-HEAD (every-harness checkout crash) + 452 slice 2 launch readiness gate + reused-mirror re-reconcile; 449 periodic mirror reconcile (host direct-push stranding); 447 stale-staging litmus false-red; 444 launch-artifact guard; receive-pack blocker closed (450) |
| v0.3.260719.1 (daily) | Windows crash-loop class closed at the host tier (operator field report 2026-07-18: fresh iex install reached the Fedora download then crash-looped with flashing terminals and zero diagnostics): windows-event-logging spec REACTIVATED as a real Event Log relay (all INFO/WARN/ERROR; the archived Tauri impl never called ReportEventW), order 417 bounded keepalive respawn (backoff + give-up + tray surfacing), order 418 registered-distro exec probe + one-shot ephemeral self-heal, order 419 launch-failure taxonomy (kernel-update / 0x80370102 / disk-full classification, pre-import host disk gate) + graceful-launch-failure spec requirement + litmus, order 420 auto-captured redacted diagnostics bundle. | Singleton guard: fs2 busy-lock misclassified as hard error on Windows (pre-existing test failing at HEAD) + forever-blocking second-instance hang → bounded deadline poll; three --diagnose spawns flashing consoles (CREATE_NO_WINDOW); fixed-5s connect loops → capped exponential backoff; order-413 ledger duplicate `events:` key merged (416 criterion 1). |
| v0.3.260716.7 (daily) | Windows-lane unblock set: order 382 (guest gitdir handed to forge uid), order 350 root cause (git-less guest push channel), windows-260716-2 (refuse credential-less mirror, fail-loud mint), vault as structural forge-lane prerequisite, router/web on-demand ensure. Orders 383 (vault generate-root seam) + 374 litmus shaped. First macOS in-forge meta-orchestration smoke PASS in the range. | Three nested-runtime panics (tray tools/call, order-235 backoff sleep, vault_bootstrap runtime seam — one RuntimeOrHandle cure); tray dead-on-arrival stale snapshot + silent launch refusals; clippy attribute displaced by merge. Evidence: ci-full 16/17 — single fail is host-local vault root-token skew (order 383), same code green on the macOS lane same day. |
| v0.3.260716.1 (daily) | Order 363: agent-reachable MCP publish tunnel (dedicated NDJSON `mcp.sock`, forge-mounted, SO_PEERCRED project gate) — implementation complete, live-publish e2e pending (order 374). FRESHNESS methodology rung 1 + packets 370-372. Order 225 litmus-stdlib `mf_*` migration batch. Windows order 238 credential research merged. Next-release milestone filed: web containers → one-prompt public share (orders 373-381). | Litmus runner: file-capture step execution + TERM→KILL ladder at the real site (dead `execute_test_command` decoy tombstoned); `tls-test-server.c` SA_RESTART SIGTERM immunity (wedged 3 gate runs); podman sqlite lock-stall cascade root-caused + ENV-FAIL preflight; `environment-isolation` allowlist caught up to `NODE_USE_SYSTEM_CA`; pre-restart fixture recovery (image-tag fallback + `ss` port-probe). |
| v0.3.260715.2 (daily) | Windows order 312 (release-gating standard-user wire), macOS orders 331/332, cross-host integration. | Clippy-strict repair forward from windows lane; stable-Rust SO_PEERCRED via nix. |
| v0.3.260714.1 (daily) | Forge runtime CA-trust convergence (one system bundle for Git/curl/Node/Python); order 320 parity checkpoint; vsock handshake litmus v2. | Six duplicate entrypoint CA blocks removed; stale v1 probe assertions replaced. |
| v0.3.260712.1 (**STABLE**) | Promoted to the stable channel — the curl-install commands above resolve here. | — |

*Older releases: distilled; see git tags and `plan/loop_status.md` history.*

</details>

## Run

**Desktop (Tray Mode):**
The installer launches the tray automatically. A tray icon appears in your
system menu bar / notification area. Click it to view projects and container status.

**Headless (CLI/Automation — Linux only):**
```bash
tillandsias --headless /path/to/project
```

## How it Works: The Fedora Pivot

Tillandsias v0.3.0 introduced the "Fedora Pivot" architecture:
- **Official Images**: Instead of shipping custom rootfs tarballs, we pull official, signed images directly from the Fedora Project (WSL2 for Windows, Cloud Base for macOS).
- **Runtime Bootstrap**: The tray application provisions the VM, installs the `tillandsias-headless` agent, and materializes your local development environment on demand.
- **Zero-Drift**: All three platforms now share the exact same Fedora-based runtime environment for your projects.

## OpenCode: Analyze Code with LLM

Analyze a project with local LLM inference (no cloud, no credentials sent):

```bash
tillandsias /path/to/project --opencode --prompt "What is the main purpose?"
```

## Platform support

### Linux
First-class support for x86_64 and aarch64. musl-static binary requires only rootless podman.

### macOS
Native AppKit tray for Apple Silicon. Uses Apple's Virtualization.framework to run a Fedora-based utility VM. Supports high-performance virtio-vsock communication and native Terminal.app integration.

### Windows
Native Win32 NotifyIcon tray. Uses WSL2 to run a Fedora-based utility VM. Supports Windows Terminal and `wsl.exe` integration.

## All Downloads

See the [latest release](https://github.com/8007342/tillandsias/releases/latest) for all platform binaries, checksums, and Cosign signatures.
Release operators should run the [local release gate](docs/RELEASING.md) before dispatching the hosted signing and publishing workflow.

| File | Description |
|------|-------------|
| [install.sh](https://github.com/8007342/tillandsias/releases/latest/download/install.sh) | Linux curl installer (`--channel stable\|unstable`) |
| [install-macos.sh](https://github.com/8007342/tillandsias/releases/latest/download/install-macos.sh) | macOS curl installer (`--channel stable\|unstable`) |
| [install-windows.ps1](https://github.com/8007342/tillandsias/releases/latest/download/install-windows.ps1) | Windows curl installer (`$env:TILLANDSIAS_CHANNEL`) |
| [Tillandsias.dmg](https://github.com/8007342/tillandsias/releases/latest/download/Tillandsias.dmg) | macOS portable disk image (Apple Silicon) |
| [tillandsias-tray.exe](https://github.com/8007342/tillandsias/releases/latest/download/tillandsias-tray.exe) | Windows portable single-file tray |
| [tillandsias-windows-x64.zip](https://github.com/8007342/tillandsias/releases/latest/download/tillandsias-windows-x64.zip) | Windows portable zip (tray + installer script) |
| [SHA256SUMS](https://github.com/8007342/tillandsias/releases/latest/download/SHA256SUMS) | Checksums for all artifacts |
| [VERIFICATION.md](docs/VERIFICATION.md) | Signature verification instructions |

The Windows portable downloads are unversioned aliases of the version-stamped
zip in the same release (byte-identical); their checksums are in the signed
`SHA256SUMS-windows`. Swap `latest/download` for `download/unstable` on any row
above to pull the newest daily instead.

## Learn More

See [README-ABOUT.md](README-ABOUT.md) for architecture, configuration, and development docs.

## License

GPL-3.0-or-later
