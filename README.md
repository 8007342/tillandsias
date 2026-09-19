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

**macOS** (Apple Silicon) — install with:

```bash
curl -fsSL https://github.com/8007342/tillandsias/releases/latest/download/install-macos.sh | bash
```

The tray provisions a Fedora VM automatically. **Prefer this over the
[.dmg](https://github.com/8007342/tillandsias/releases/latest/download/Tillandsias.dmg):**
Tillandsias is signed but not yet notarized (Apple Developer enrollment is
pending), and macOS tags anything a *browser* downloads with
`com.apple.quarantine` — so the .dmg route hits a Gatekeeper block on first
launch, while `curl` does not tag at all and the app opens normally. The
installer also clears the attribute if you did take the manual route.

If you are already stuck on a quarantined copy:

```bash
xattr -dr com.apple.quarantine /Applications/Tillandsias.app
```

On macOS 15+ right-click → Open no longer bypasses the block. If macOS offers
only "Done" / "Move to Trash", open the app once, then go to **System Settings
→ Privacy & Security → Security → Open Anyway** — the button appears only for
a short window after the refusal.

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
| v56.9.19.1 (daily — cut 2026-09-19 by the macuahuitl coordinator on the operator's fix-forward instruction, the first cut after the 2026-09-18 fleet restart and BigPickle's NPU/iGPU/GPU passthrough layering on the Silverblue hosts; PR #117 merge + bump PR; gate on 139e7027b `./build.sh --ci-full --install` on macuahuitl: pre-build 369/369 litmus, launcher built + installed, post-build 12/13, runtime residual 5/5 — a COMPOSED VERDICT (post-build and runtime re-run standalone at 08:41Z/08:58Z against the installed launcher after gate #5 ended on the same one red); five gates were needed: #1 red on a stray `/tmp/tillandsias-timing.jsonl` this session had written (metrics-log-split guard, correct), #2 GREEN 03:20Z but the plain `--ci-full` runs NO post-build/runtime phase (the runbook under-gates every cut — row queued), #3 `--ci-full --install` red on the meta-orchestration e2e killed at the litmus shim's 300s Container budget (fixed 77490d6ff, the shim must mirror production's attached run), #4 red on the SAME kill because the shim resolved a four-day-old prebuilt `tillandsias-podman-cli` by existence (rebuilt; stale-binary family row queued), #5 the one red above; the operator ruled ship-with-that-red at 15:40Z; KNOWN RED SHIPPING: litmus:opencode-prompt-e2e-shape — the forge LAUNCHES (launch proven) and the OpenCode agent inside dies on "Error from provider (Console): Rate limit exceeded"; the operator suspects that e2e phase of invalidating credentials on hosts (gnome-keyring-daemon crashed on this host at 03:01:37Z inside that phase, GLib assertion in its D-Bus property handler, and lenovinha saw the same; under investigation); the curl-install smokes carry their own agent smoke); RELEASE RUN 35453526671: Linux musl GREEN (15 assets incl. launcher, both headless guests, sidecar, installer, cosign bundles), macOS tray GREEN (dmg + tar.gz + SHA256SUMS-macos), WINDOWS TRAY RED — no Windows tray shipped for v56.9.19.1: the Windows packaging script now builds the native headless probe binary beside the tray (1171-ccf2, since v56.9.13.1 — the last green Windows job never compiled the crate) and tillandsias-headless's build.rs (1b5b5a856, 723-wd8i) refuses when images/router/tillandsias-router-sidecar is absent, a build artifact build.sh stages and the Windows job never did (its staging step downloads only the guest headless); yolanda compiled the tray natively clean at the tag and attested the four drifted Windows-only sources (hvsocket.rs, installation_uuid.rs, notify_icon.rs, wsl_lifecycle.rs), so it is a runner staging gap, not a source defect; FIXED FORWARD as v56.9.19.2 (the workflow stages the published sidecar asset for the Windows job) | THE RUST+REDB+LUA RUNTIME FOR ./plan, the operator's stated priority: redb ledger cache (964-tzmp; point query 7ms vs a full load), the Rust command executor `tillandsias-exec` with argv-only Command, separately captured and concurrently drained fds, status as a value and a RunId on every Result (1252-fg9e), the Lua predicate bridge whose Cacheable class cannot resolve `sh` or the clock — purity enforced by symbol absence, a ruling not an inheritance (1252-hsrz), the structured litmus `assert:` mechanism and a PARSE ERROR for a critical_path item opened by any key but `step:`, and the 45 exit-code steps migrated to `assert_exit` (1252-znbn; one of the 45 executed both ways, 44 parsed; the 23 non-empty-output steps relay next, so at the tag the `grep succeeds` steps are still adjudicated by the old non-empty arm), the tree-sitter bash-composition-hazard advisory lint bound under ci-release (1252-r72q). Read-only tokens are a supported scenario: the 759-vceg login push probe and its three structure-pinning tests DELETED per the operator's ruling (1217-54vw; the forge-launch push test filed as 1264-s4id). One canonical skills tree by directory symlink with both guards widened (631-wpkd, 1238-u84w, 1255-rvr7). Accel probe: WSL2 dxg enumeration via a runtime-dlopen'd Vulkan loader with a criterion-3 software-rasterizer rejection (793-zumy; the driver-store mount that makes the container lane usable is in the next relay per the operator's qualified yes); four probe/recorder literals filed (1253-54zj NPU usable:false, 1254-pxw6/47xd iGPU + unverified container lane, 917-n3n9 lane env default). Smoke runbook evidence archiving + cold-host guard-stop (1189-7yvu, 1190-swen). Capability rows for the passthrough hosts. Fourteen packets filed from one night's instrument defects (1253–1266), incl. the status-channel parent 1260-2qgi (a status is preserved or declared absent; verdicts are ternary), 1259-kn83 (a slow host loses the merge-before-push race), 1260-4a59 (a stale platform branch cannot fast-forward-push a tree identical to trunk — FIXED in this cut, agreeing deletion = agreement), 1261-bn7v (--append blind to a peer's newer append — the lane now refuses drops-lines-vs-origin), 1258-8wfb (the Windows installer LOST its post-install --diagnose health check on 2026-06-23 and the litmus guarding it passed on non-empty output for three months — NOT fixed here) | vault bootstrap in a container without selinuxfs now labels `label=disable` instead of aborting (d8f46576d, the ci4 forge-lane cause); the vault root token travels on STDIN to a shim inside the container — the builder toolbox's podman is a flatpak-spawn wrapper that drops the caller's environment, so the name-only `-e VAULT_TOKEN` pass-through ran every release-gate vault read tokenless (403) and killed the forge launch (6ff027fce); the litmus-runtime podman shim ran an attached `run` through the bounded, captured execute and killed any forge session at 300s (77490d6ff); the litmus runner never exported the podman it resolved, so two inference litmus fell to `/usr/bin/podman`, absent in the toolbox (e76a77210); an orphaned parity annotation moved onto its function and two dead surface_baseline entries dropped; a bash-4 `mapfile` in a wrapper that runs on macOS 3.2 (761-g36m); a ghost @trace to a milestone that is not a spec; LC_NUMERIC: awk `%.2f` prints `100,00` on comma-decimal hosts and every `[0-9.]` consumer truncates it — pinned LC_ALL=C on producer AND consumers in bench-inference-floor.sh and the openspec pre-commit hook (1254-fdsu; macneo's one-string-three-values measurement: `3,500` is 3500 under en_US, 3 under C, 3.5 under fr_CH); the inference image pinned to a concrete version tag instead of :latest; two skills guards that asserted per-skill symlinks over a directory-symlink layout and reddened trunk in two lanes; the salvage-audit fixture ARM 2 and the claims-fleet-visible scratch lane (relay-time defects, both fixed); the Vulkan ICD segfault at non-main-thread exit avoided by never destroying the instance and memoising enumeration once per process (esme, 793-zumy) |
| v56.9.13.1 (daily — cut 2026-09-13 by the macuahuitl coordinator on the operator's instruction, the first cut after the 2026-09-12 fleet restart; PR #115 merge + bump PR; local `./build.sh --ci-full` on 0c53aa4ae: first attempt on 0c53aa4ae RED rc=1 (1534s) on one check, litmus:ensure-toolbox-include-shape step 5, fixed forward as 1175-wuwr; re-gate GREEN rc=0 — ./build.sh --ci-full on 7a089997d, 1522s (00:18Z–00:43Z) on macuahuitl, 33/33 checks, 358/358 pre-build litmus; 84 feat/fix commits since v56.9.12.2; **PROMOTED TO STABLE 2026-09-16** on the operator's instruction, by flag flip rather than a fresh cut, so `/releases/latest` serves the exact artifacts the blessing round verified (952-mrsl) — curl-install smoke PASS on all three platforms before promotion: esmeraldinha (Windows), pirria (Linux), tlatoanis-macbook-air (macOS). Two defects ship with this stable and are named rather than discovered: **1171-ccf2** — the Windows zip does not carry `tillandsias-headless.exe`, fixed on trunk but NOT in this tag; and **1215-xazj** — p1, the tray's `--github-login` cannot succeed on any platform because the 759-vceg push probe resolves its repository from the process CWD while the tray always runs the login in the guest, which has no checkout. 1215-xazj is unfixed in stable, in the daily and on trunk, so this promotion raises the version without repairing it) | **The fleet-restart hardening window (2026-09-12/13)**: the documented Linux reset now clears the host-held Vault credentials so the clean room is credential-cold for the first time since June (900-z3kv); the land tool retries a push once after an auth blip and never re-auths (1164-cftu); the meta-orchestration loop got its token counter and reporting (1119-6wn6), the stale-ready-row reconciliation pass (1144-jfr5), the competing-gate detector with its named codes (1141-vf9w, 1150-q462), and the first supervised de-slop sweep with its protocol as a skill (829-dkuc). Capability truth: the envelope names whether it was measured or served (1139-xe5m); the Windows probe refuses a runnable-but-stale binary by vocabulary, never mtime, and yolanda's wrong row is republished with the Radeon 860M and the NPU (1172-dyvd); the capability-row guard no longer fails open on age and names a remedy that cannot run where the verdict fires (1154-8ywc, 1165-xkjh — `stale:capability-row-expired` where `ok:capability-row-reported` used to answer is the fix working, not a regression). Silverblue: the akmods depsolve skew is documented with a read-only probe (1165-g6wx). macOS: `clamp-ca-material.sh` was inert on BSD stat and now clamps (1135-z8gn); the accel probe carries `name_source` (1137-rgfm). Browser enclave host-network default (1118-dwgx). | Env-var test races in the headless crate (1146-z8ux), the salvage net's unpushed-clean-tree and symlink gaps (1146-8j7i), the salvage sweep writing to an archived packet (1148-3439), compaction reading only one LWW channel and its blind coverage guard (1156-eif4, 1157-ghmi, 1158-y3ad), the credential-helper host pin versus its fixture (1161-42pc, 1118-bscs), the dead-env detector's four blind spots (1166-99mk…1169-zw44), the reaper's SIGPIPE-under-pipefail flake (1076-kft9 class), ten fixtures restored to mode 755 after landing 644 from Windows, and the cheatsheet tier check (1140-d6ni). Known and unfixed in this cut: 1159-g96c (`due:no-capability-row` from a third context on a two-locus host, expected from a builder distro), 1171-ccf2 (the Windows zip does not yet carry `tillandsias-headless.exe`; esme's probe refuses loudly). |
| v56.9.12.2 (daily — third cut of 2026-09-12 by the macuahuitl coordinator, the control-wire keying fix; PR #113 merge + bump PR; local `./build.sh --ci-full` on 46bc11426: GREEN rc=0 — ./build.sh --ci-full on 46bc11426, 1273s (09:01Z–09:23Z) on macuahuitl (20c, Fedora 44); litmus and checks all green (log: ci-full.log); release run 34685995464: ALL THREE JOBS GREEN; PROMOTED TO STABLE 2026-09-12T10:52Z on: macOS cold curl-install smoke of the CI-built tray on macbookair — substrate zeroed, provisioned from nothing, host had guest metrics at 38 s (v56.9.12.1 timed out at 300 s on the same procedure); Windows CI-built tray on yolanda reached Ready in 38 s with the injected guest byte-identical to the published asset (in-distro arm, prior state, `wsl --unregister` consent not granted); Linux full smoke §1-§3 on cachyos with its operator's consent — install 175 s, `podman system reset` to 0/0/0, init 398 s from a pristine store with 15 images rebuilt and vault healthy, clean against every failure class the runbook enumerates; Linux §1 on macuahuitl (78 s); Windows §1 on esme (22 s). Not run: a pristine-host Windows provision (per-run consent). Found one step past §3 by the same run: `tillandsias-vault` is SIGKILLed (137) on every shutdown because the image's entrypoint installs no trap — 1134-u934, p1, fix and a runbook §3b routed to pirria) | host↔guest control-wire PSK keyed to the guest binary's digest known at tray build time instead of each binary's own self-hash (1084-x8ya; macOS 2976154d8: guests build before the tray, `build-macos-tray.sh` exports both digests; Windows 838922d02: `build.rs` digest of the embedded asset, None on a placeholder with a runtime refusal); the old unkeyed entry point refuses on release with a named cause; a mismatch arm that goes red on equal digests; the guard auditor searches the canonical `skills/` tree (7b9b58e55); the plan-only push lane refuses what it cannot fold (1124-7f3u) and the gate memo runs the ledger guards on plan-only changes (1127-waxf) | ripgrep path operand — the cheatsheet check no longer hangs on a piped stdin (d15aaf3d4); metrics split guard scoped to the reporting path with a mv-aside remedy (1096-p3tn); `test-gate-stamp` fixture portable to BSD sed; land-script push bounded with a named refusal on an empty push log (1131-iax2); 1129-3yv7 Windows gate as root; 1127-apa8/1128-4ffr/1129-xm5z Windows-lane defects. KNOWN DEFECT SHIPPING: on macOS a non-empty but malformed embedded digest passes the build refusal and falls back to the unkeyed self-hash silently — unreachable through build-macos-tray.sh (64 hex by construction of the producer), fixed on osx-next at ede57fcc0 after the cut, rides the next daily |
| v56.9.12.1 (daily — second cut of 2026-09-12 by the macuahuitl coordinator, the Windows rebuild after 1122-xi2f; PR #111 merge + bump PR; local `./build.sh --ci-full` 356/356 litmus + 32/32 checks on b026372ff; release run 34668648875 dispatched 02:48Z and IN PROGRESS when this row was written — per-job results and assets are in the work-queue line for this tag; STABLE CANDIDATE pending three-platform curl-install smoke by the restarted fleet, plus a detached forge lane on macuahuitl) | Windows tray placeholder check covers exactly the embedded arch (1122-xi2f, confirmed on yolanda: packaging succeeds, 8/8 fixture arms with the PowerShell arms executed); the fragment-status-loss guard understands a reopen after falsification (ac0ea1089; lifted a fleet-wide landing freeze); the plan-only push lane hole is filed (1124-7f3u); fleet restart drill and assignments (plan/issues/fleet-restart-2026-09-12.md); release-gate install side effect documented with the roll-forward ruling (1122-6sqz); ~/src retirement verified on macuahuitl (776-jcf3); 1115-yvrq selector fix (claimability is satisfaction, not containment; yoga) | none new in code; known and filed: cloud-mode Observatorium leaf (1119-w2rj), credential remedy re-mints (1119-9yjk), in-gate-only fixtures (1120-s3e5), a macos-tray unit test overwrites the live crashloop.state on every Mac gate run (1127-xm3m), two probes answer about themselves (host-tools rustup PATH, Windows capability rows labelled linux_mutable) |
| v56.9.11.1 (daily — cut 2026-09-11 by the macuahuitl coordinator's recovery cycle after the 2026-09-06 cut was parked on five gate reds; PR #109 merge + bump PR; local `./build.sh --ci-full` 356/356 litmus + 32/32 checks on 9125c71df; **Linux + macOS published, Windows job FAILED** (1122-xi2f — no Windows tray in this release); no macOS/Windows host smoke, both hosts down since 2026-09-06) | host-checkout elimination for cloud launches (440cde994, 776-jcf3 progress: tray + CLI no longer touch `~/src/<project>`); ephemeral-guarantee spec (8c9c9bd21); ledger-write reachability gate step, 1080-4deb ARM 1 (53256cb70); memo-hit observability closed (1074-96z9); answer-rate fixture cost fix closed (1105-h8vr); capability-manifest fixture isolated (af7529a26, 1114-p2ht); OAuth 10-token-cap research closed (1025-a896); sub-agent and token budget rules in both skills (1119-6wn6, counter open); 889-fragment ledger compaction | forge `/home/forge/src` tmpfs mode 0777 so the forge clone no longer fails with permission denied (440cde994); `+x` restored on finalize-cycle.sh (20646f4df, 1116-vps5); `forgotten` added to the plan capability manifest (061b0c66e); committable-branch fixture sets its own git identity (82f1001bf, 1109-t8kw); CODEX.md allowlisted, deslop health guard wired, routing fixture stubs the 1034-whsp fold (9125c71df). KNOWN, FILED, SHIPPING: cloud-mode Observatorium leaf cannot show the repo + `is_cloud` inferred from env (1119-w2rj, p1); credential guard's 401 remedy re-mints tokens (1119-9yjk); three fixtures red in-gate only (1120-s3e5); the release gate reinstalled this host's launcher (1122-6sqz) |
| v56.9.5.1 (daily — cut 2026-09-05 by the coordinator's 01:47Z cycle after the 00:09Z meta cycle deferred it on three host fixes; PR merge + bump PR; union litmus 291/291 and the tool's gate on the merged trunk; 172 commits since v56.9.4.1) | Tray honesty on every platform: macOS `--diagnose` no longer prints "healthy" from a stale crashloop.state, it prints the recorded verdict with its source and age and says no live probe was made (980-ja2m slice (a), macneo's design landed by macbookair); the Windows Guest health line says what it is and how old it is (1032-utne); the LocalProjects wire surface removed and WIRE_VERSION bumped to 3 with every ControlMessage discriminant pinned against measured literals (997-e4v2 step 3, 1029-5wvd); the client-side wire-version refusal actually tested (1032-62rx); order 505's project-label validation fails CLOSED on an empty enumeration at all four sites including the MCP tool socket (1031-q4pb, security); a failed forge launch no longer wedges the next one and never kills a live sibling: exited corpses cleared by state, running holders waited out with a bounded backoff, --replace removed from both forge builders (873-vgyg); the secure control wire's readers share one parser with a ratchet toward a single reader (972-umik, default unchanged pending the atomic flip). | The two tray crates declared the same [[bin]] name so a full-workspace gate ran the wrong platform's stub by link order (1043-kvvn, unique-bin-names guard); the proxy parse gate pinned a stale launch string (1022-px54); the freshness-inventory walk was quadratic bash, 18 s → 0.7 s, and an empty inventory refuses instead of reporting 0.0% (1038-d7vw [regime footnote, esmeraldinha v56.9.5.1 floor round: the 18 s → 0.7 s is the ext4 regime; on the Windows floor's drvfs checkout the fixed walk measures 13.5 s, 725 ms on the same box's ext4, so the fix is verified there and the headline number does not travel]); three vacuous tray absence asserts (1028-3eiz); cheap deciders hoisted ahead of the compile so a red refuses in 2 s not 222 s (1009-gccx); the scorable-obligation gate anchored (1036-jamx); the metrics litmus re-pinned to WIRE_VERSION 3 (relayed from windows-next by patch); the release ledger row's gate claim for v56.9.4.1 corrected. Known open at cut: the host-class build tune-ups (1047-h88p: the freeze is the test phase's I/O, not the compiler), the Windows gate-stamp documentation (1039-b64k), the memo's mode-bit scope (1036-e5w9), the tokens investigation (1025-a896, operator's log read pending). |
| v56.9.4.1 (daily — cut 2026-09-04 by the coordinator's 20:09Z meta cycle, PR #105 merge + bump PR; gate `./build.sh --ci-full` green on 822560ae9 at the FOURTH attempt after 1022-y7kc's thirteen host-state and gate-instrument causes were fixed (the third attempt on 89dce1844 was red on two of them); 900 commits since v56.9.2.1) | Hardware placement: the AMD Vulkan lane places (520, measured on gfx1152; images older than 32dc4278c are CPU-only on AMD), accel envelope side- and engine-qualified per phase (793-qr4t/qc6q/zumy), the capability matrix keyed on (fingerprint, substrate) with the Windows probe now seeing the NPU (805-r98w), devices report whether memory is their own (964-r98h), the tier's model warmed at forge start (965-hz3f). `tillandsias --ensure-enclave` restore path (1004-xw3q). Guest vsock relay to host-native services (830-xsk2). Guest binary staged off ~/src (1019-ivia) and the Linux tray's ~/src row retired (997-e4v2 step 2; step 3 in flight on osx-next). Cycle metrics: every cycle names its repeated and skippable steps (1001-q3zf). Spec requirement identifiers for all 653 requirements (976-suab) and the obligation lattice in code with enforcement that refuses silence (977-*). Stale-base revert refused at the receiving end (1001-i5ux). Gate now runs every workspace crate's tests through the ratchet (1003-444f). | 73 fixed orders, among them: headless shutdown escalation SIGKILLed unowned containers (1019-ba6e) and still stops the live vault/proxy on exit (1020-iicv, open); `podman rm` satisfied the enclave health check (1004-inkc); a grep-shaped fixture that could not fail (1021-a944); litmus [FAIL] lines without exit status (1018-5f5a) and a control arm on a moving ref; local-ci's tray-contract arm serialised like the gate (1021-hf9e); the smoke runbook's PIPESTATUS-under-zsh and missing Windows §3 (1004-fue3); the credential guard green on file presence and blind to timeout/busctl on macOS (988-7kxf); the mac HOME baked into the guest CA preamble (1002-9xmb); present-but-unusable accelerators made the bring-up lane (1002-7jeg); the state root declared twice (1027-539s); the gate's stale pins and the bare ci-full downgrading the local launcher (1022-y7kc causes, recorded). Known open at cut: the operator's gh tokens revoked server-side on three hosts with no mechanism found (1025-a896); 1022-px54 p1 in the floor tier. |
| v56.9.2.1 (**STABLE** — cut and promoted 2026-09-02 unattended, operator-authorized while asleep; PRs #103 merge + #104 bump; gate `./build.sh --ci-full` green on f9f383256 after two host-state reds were traced and cleared — a cold keep-id layer copy of the freshly rebaked forge image timing out four forge fixtures, and stale guest-binary staging from a bumped `--install` run; release run 33654705874 all three jobs green in 72 min, 32 assets; Linux asset blessed on macuahuitl by SHA256SUMS + `--version`; flipped to stable 17:40Z) | Fail-loud diagnosis: dev-inference exit(2) root-caused to the 128 pids ceiling and fixed (811-28eh); litmus runner: kill-time adjudicator diffs the runner's own cgroup cpu.pressure, retired-phase tests run only when asked, killed tests record censored time, stdin no longer swallows a spec's test list — 36 hidden tests now execute (956-llei); ghost-trace gate scans yaml and markdown (867-vd4z); measurement practice in methodology with `build_check_mix` at emission (890-nkdz); hardware fingerprint that refuses an untrue twin claim (805-r98w); tray broadcast write bounded (832-me6z); durable Linux launch-failure breadcrumb + NVIDIA CDI classification (665-zddn); 793-zumy Reachable/Placed producers; login flow checks authorization, not only authentication (759-vceg) | Lane socket listener never bound by the live launcher (mcp-lane); seven pids-limit sites aligned at 4096 (959-fpc5); three born-red litmus tests repaired (diagnostic guard grepping its own removal comment, day-boundary mutation control on a live clock, bare jq in local-ci); approved-UX-strings gate reads the archive; capability-routing fixture aligned with 949-uv5k seed semantics; debug-gated stderr echo that killed `set -e` sourcing shells (797-thbw); attach screen-home at the boundary (702-6jza D1); merge runbook speaks epoch versions (952-mrsl); vault self-heal asks the key it just unsealed with (803-49re) |
| v56.8.31.3 (**STABLE** — promoted 2026-08-31T22:20Z via PR #102 on yolanda's full blessing round, the FIRST round to run every leg unattended from downloaded release assets, forge launch included (945-vpg3 closed the operator-click gap): 8 Windows assets by name, checksums 4/4, zero CR bytes instrument-confirmed after her own first measurement produced a false 4 (`grep -c $'\r'` collapses in Git Bash; `tr`+file(1) settled it), binary reports the tag commit b8ac355fb exactly, MSIX honest-withhold, `--reset-guest`/`--provision-once`/`--forge --shell` all green from the downloaded binary, negative control refused. The promotion's own ci-full gate went red TWICE first and both rounds were real: the versioning-shape litmus still pinned the retired scheme (the drift-protection had drifted), and a duplicated `#[test]` had silently unregistered a sibling tray fixture that had NEVER RUN — restored, first execution passes. Promoted by flipping this release's prerelease flag: no re-cut, so stable serves the EXACT artifacts the blessing verified. Supersedes v56.8.31.1 and .2, both same-day, both incomplete Windows asset sets, left standing per fixed-forward) | **milestone: v0.5.** **The version scheme goes epoch-anchored** (operator ruling 2026-08-31): `<years_since_epoch>.<month>.<day>.<build>` — 56 = 2026 — replacing `Major.Minor.YYMMDD.Build`. The cutover is structural, not procedural: every comparator (field-wise, `sort -V`, git version sort) resolves at field one, 56 > 0, so every epoch tag orders after every legacy `v0.x.*` tag with **no tag rewrite and no flag day**; legacy VERSIONs auto-migrate on the next bump with a NOTICE; `--bump-minor` is retired loudly — milestones now live in the plan ledger's `desired_release` ordered buckets and this row's milestone clause, decoupled from artifact versions (`openspec/specs/versioning/spec.md` rewritten as the source of truth). **The MSIX encoder retires with it** (yolanda, 776-g6r3/62652e063): the Windows packager reads the four fields directly and emits `56.8.31.0` — under the old scheme YYMMDD blew the Store's 65535 per-field cap, so **every MSIX this repo had ever produced was Store-invalid**; now the manifest is Store-legal at the source. With that, **all three Store submission blockers are closed**: version legal, identity matching Partner Center (macron intact), and Microsoft re-signs Store MSIX at $0 so the unsigned-sideload problem does not block that channel. Standing constraint recorded: field four is the Store's, so all same-day builds derive the same `56.8.31.0` — **one Windows Store submission per day by design**. Also aboard: the five 944-jaef tray freeze fixes complete (GetLayout parent_id/recursion_depth included — the 260830.5 row's do-not-relaunch warning is **lifted** at this build), unsigned-MSIX withheld from release assets with its checksum line dropped LF-clean, a CR-byte invariant asserted in the consuming job, 936-kdev's container sweep scoped to stack-managed names, and the fleet's 2h staggered loop cadence. | **Three cuts to get one clean release, every red its own lesson.** **v56.8.31.1 shipped ZERO Windows assets**: the new unsigned-MSIX withhold guard rewrote `SHA256SUMS-windows` with PowerShell `Set-Content`, which emits CRLF, so `sha256sum -c` hunted a file named `…zip\r` — the guard protecting the checksums corrupted them (root-caused by yolanda, f77897371; her held fix was then falsely reported as merged — one grep against the ref disproved it, and the doomed re-run was cancelled pre-tag). **v56.8.31.2's first dispatch died at HTTP 422**: the coordinator's heredoc embedded a literal CR byte in the CR-invariant's own comment, making release.yml unparseable — the line-ending defect infected its fix's commentary. Its second dispatch published Linux and macOS, then **Windows died at `msix-version-unmappable`**: the trunk packager still parsed a six-digit YYMMDD out of field three, because the cutover's windows-owned half existed only on yolanda's machine — her built-manifest verification was green *against her working tree* while the runner held trunk's copy. Named on the ledger as the night's sharpest variant: **a green that does not name which artifact it verified can be true and useless simultaneously**; verifications now state their ref or state working-tree-only. v56.8.31.3 is the first cut with both halves of the cutover aboard: run 33435063050 green, 8 Windows assets present by name, no MSIX in the asset list (the withhold working as designed on an unsigned build). |
| v0.4.260728.1 … v0.4.260830.5 (12 rows, 10 releases, **DISTILLED** — see the policy below; two rows were duplicated appends of v0.4.260817.1 and v0.4.260826.1 and are folded here once) | The v0.4 series, cut 2026-07-28 → 08-30. Opened with the three-branch convergence and the terminal-attach@v2 wire (`.260728.1`, stable) and the Windows login-gate recovery (`.260728.2`, stable, Shamir-share self-heal). `.260804.1` was the first release gated ENTIRELY on local hardware after push CI was removed (`./build.sh --ci-full` + `release-preflight.sh` as the whole gate). `.260809.1`/`.2` introduced the release-channel split (rolling UNSTABLE prerelease, `--channel`, version-stable Windows portable aliases) and `.260810.1` was the first stable promotion to satisfy `promote-stable.sh`'s evidence gate on real three-platform curl-install e2e. `.260815.1` shipped the operator-gated promotion with the linux-immutable overnight wave (MO-FULL attestation ledger, expert health probes). `.260817.1` was cut on a durability request: the Vault credential helper wired into every mirror fetch path and the Windows `WSL_UTF8=1`-by-construction wave. `.260826.1` (stable) brought capability-aware work routing over the shared matrix, the durable cycle scheduler, the dead-versus-wedged heartbeat, and the persistent nix store as a signed binary cache; `.260830.5` the grounded-expert pipeline (expert-serve, answer-or-typed-refusal) and the accel-truth wave (DRM render nodes, NVIDIA CDI on Silverblue, a measurement harness that refuses to fabricate). | The ledger-integrity wave (635-i6vm: 11 of 21 fragment completions silently dropped by the fold; 641-e2qa: stranded in_progress rows), 623-iwq4 (Windows SHA256SUMS), the Gatekeeper fix (421), the order-462 diff-base reconciliation and the 494 leak-not-destroy guard, and the Local Experts mode disarmed after its agent narrated a pipeline never invoked. Evidence trail: `plan/issues/` rows dated 2026-07-27 → 08-30. |
| v0.3.260712.1 … v0.3.260724.1 (10 releases, **DISTILLED** — see the policy below) | The v0.4 stabilization run, cut daily 2026-07-12 → 07-24. `v0.3.260712.1` was that series' stable; `.260721.1`–`.260724.1` were the order-455 cross-platform smoke pre-releases. Landed across the series: the Windows lane to CODE-COMPLETE, with WSL-absent as a first-class runtime state; the git-mirror Vault Agent auto-auth relay surviving token max-TTL without restart (order 424); the agent-reachable MCP publish tunnel over a forge-mounted NDJSON socket (order 363); forge CA-trust convergence onto one system bundle; and the first release PR gated by real CI, whose maiden run caught four latent type errors in the new windows/macOS cfg-typecheck lanes. | The Windows crash-loop class closed at the host tier after an operator field report (fresh install reached the Fedora download, then crash-looped with zero diagnostics); the singleton guard's busy-lock misclassification and its forever-blocking second-instance hang; a shipped `.ps1` that parsed as a DIFFERENT program once saved (BOM-less UTF-8 em-dash → CP-1252 smart quote — every `.ps1` is now pure-ASCII under a litmus); three nested-runtime panics cured at one seam; six duplicate entrypoint CA blocks. |

**Distillation policy** (order 380). This table is read by humans AND by the
curl-install smoke, which extracts the row for the tag it is about to test and
must account for that row's claims in its report. Both readers want the same
shape: *detail on recent releases, summary on old ones.*

- **Detailed rows** are kept for the current series and for every release still
  reachable by the install commands above.
- **Once the table exceeds ~10 detailed rows**, the oldest series is collapsed
  into ONE distilled row spanning `first … last`, naming what the series
  delivered rather than what each release did.
- **A distilled row names its span and says it is distilled**, so a reader can
  tell a summarised range from a release that simply had little to say — and so
  the smoke can tell "no row for this tag" (a finding: either the release skill
  did not append, or the artifact is undescribed) from "covered by a distilled
  span".
- **Nothing is deleted, only compressed**: per-release detail stays in the git
  tags and `plan/loop_status.md`, which the distilled row points at.
- **One row per release.** A re-cut or re-promotion EDITS that release's row
  rather than appending a second one.
- **Two pre-existing pairs predate this rule** and are NOT resolved here:
  `v0.4.260826.1` and `v0.4.260817.1` each appear twice, and the pairs are not
  copies — the second of each is a later, richer rewrite. Choosing which
  description survives deletes prose someone wrote, so it is left to the
  ledger's owner and tracked on order 380 rather than settled by whoever next
  edits the table.

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
| [Tillandsias.dmg](https://github.com/8007342/tillandsias/releases/latest/download/Tillandsias.dmg) | macOS portable disk image (Apple Silicon) — quarantined by the browser; prefer `install-macos.sh` |
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
