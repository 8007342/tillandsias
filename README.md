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
| v56.10.9.1 (daily — fix-forward of v56.10.8.1, which published **without macOS assets**) | Cut 2026-10-09 by the macuahuitl coordinator under the operator's standing rule. **macOS release build**: `open(2)` declared variadic so rustc 1.99 (the runner's floating `stable`) accepts it (#264). **Reinstall handover**: a Superseded old instance now hands over instead of being ignored, on Windows and macOS (1562-bqcg #255, macOS test #257). **Uninstall**: one big red "cannot be undone" confirmation naming the Vault and sign-ins, default cancel; no TTY refuses unless `--yes` (1437-evzi #265, #266; operator ruling 2026-10-08 — installers stay SOFT-only with no prompts). **Windows**: SOFT-only installer stack and fixes (#243 #245 #247 #249 #250 #251 #259); log capture keeps stderr (1563-u2yx #261). | Release gate 1 (51c0e29bf) red on `litmus:uninstall-preserves-vm-image`: #265's no-TTY refusal made the headless steps remove nothing (one red, one vacuously green) — the `--check` tier never runs the pre-build litmus; fixed by #266, gate 2 green at e3e3f31d2 (440 passed, 0 failed) + `ok:release-preflight`. Bump gate red on `test-fleet-activity.sh` ARM 2 (window derived from HEAD, check reads origin/linux-next; GitHub's fresh merge commit split them) — fixed by #268 (test-only, landed at full tier) and promoted by #269; the shipped tree differs from the `--ci-full` tree by that one test file plus one plan fragment. gnome-keyring crashed under gate 2 (1562-kr7c). |
| v56.10.8.1 (daily) | Cut 2026-10-08 by the macuahuitl coordinator under the operator's standing rule (cut without asking; promote when every gate and per-platform smoke passes); 11 days and ~230 landed work refs after v56.9.27.2. **Lua runtime**: `script run` is the one Lua decider runner for gate and door (1384-bqhy/ddua); script-owned process supervision with bounded launch, reap, streaming and callbacks (1534-puyz, 1538-pwdr, 1539-dt84); a dead worker is a crash, a slow spawn is latency, a held pipe is that child's result (1551-7hyq/333i/af3e/sprq). **Fleet messaging**: `tillandsias-plan msg` lane store, `--msg-serve` same-host mover, forge-plan MCP msg_send/recv/list/status (1506-nvqt/q7ab/ssb5); fleet host score and services affinity (1548-dylo). **Cloudflare login**: PKCE core, Vault two-path token bundle with rotation, `--cloudflare-login --via loopback|qr|paste` and logout (1505-kyx8/iysn/kc5f/iky3); local Wrangler + HTTPS preview of forge worktrees (1552-e3wf). **macOS**: guest clock set from the host on every wake (1503-qrgz); guest disk starts at 20 GiB and grows to a 50 GiB cap (1481-2bth); VZ stop marshalled to the VM queue (1429-u2wd). Every tray.log line carries an ISO-8601 UTC ms timestamp (1479-9hx6). | The git mirror decides BROKEN by failing layer with hysteresis and stops writing a fatal line every 2 s (1310-rec6); a failing agent profile never kills the forge entrypoint (1517-p83m); a failed image build names its step (1502-utcy); no interactive GitHub token-paste prompt (777-kyjp); login signalled before the git-identity prompts (1486-y67a); colour-tier QR codes cannot stripe (1480-eqkh); per-router IPv6 egress probe (1548-mhyk); a claim refuses past the host WIP limit (1367-2sbc). **Release tier**: the first `--ci-full` was red on clippy `double_must_use` (async_trait, 22 sites) and a zero-trace spec; fixed in #248 (local-ci clippy flags match the workspace's, `@trace spec:host-state-lifecycle`), with the census litmus pipes and web-wrangler allowlist fixed in #225/#237. Gate: `--ci-full` rc 0 (42/42, 1 advisory skip) + `ok:release-preflight` on 4e4d96a5e; the 3 commits landed during the gate were plan-only fragments; bump branch gated `--check` scope=full. Not in this cut: the 1437-3iux reset/installer stack (held for the 2026-10-08 installer ruling). |
| v56.9.27.2 (**STABLE** — promoted 2026-09-27T17:3xZ by the macuahuitl coordinator under the operator's standing rule, on three per-platform smoke PASS reports for this exact tag: Linux yoga (the destructive --reset-state leg deliberately UNMEASURED — it wipes the operator-seeded token), macOS tlatoanis-macbook-air, Windows yolanda (cosign 4/4); `promote-stable.sh` → promoted + verified:stable-tag:52e3bc32e; fix-forward of v56.9.27.1) | Cut 2026-09-27 by the macuahuitl coordinator under the operator's standing rule (cut without asking; promote when every gate and per-platform smoke passes). **Why**: v56.9.27.1 lost its Windows assets because Git Bash MSYS argument conversion mangled the cosign identity regexp (`\.` → `/.`); the regexp is now written with `[.]` (measured by yolanda: `\.` rc=1, `[.]` rc=0), and the integrity check now reports cosign's own refusal reason instead of "bytes changed" (1425-8wir). **Also ships**: the `tillandsias-progress-tty` renderer crate — tillandsia-palette bars with truecolor/256/plain tiers (1420-9vpk, the pretty-installer foundation); the plan-binary probe-usage guard is deterministic again — three `printf | grep -q` pipelines under pipefail flipped litmus eligibility 11/12/13 across runs (1130-qk7d's mechanism, second instance; caught by this cut's first `--ci-full`, which therefore failed and was re-run); Mac gate fixtures resolve the checkout's plan binary from scratch roots (1427-utmy); the experts ground-truth corpus follows 437's closure (1432-x3ug). Gate: `--ci-full` + release-preflight green at 70da438e7 (second run). |
| v56.9.27.1 (daily — **Windows assets NOT published**, so it cannot be promoted; fixed forward by v56.9.27.2) | **Defect (release run 36287645166)**: the Windows job signed its five assets and the new cosign arm of the integrity check (1407-6jr8, first live run) refused all five, because Git Bash MSYS argument conversion turned every `\.` of the identity regexp into `/.` (SAN mismatch; the signatures were fine). Measured by yolanda on cosign v3.0.5: `\.` rc=1, `[.]` rc=0. Fix: the regexp in release.yml is written with `[.]`. Linux assets published and verified 8/8. Cut 2026-09-27 by the macuahuitl coordinator under the operator's standing rule (cut without asking; promote when every gate and per-platform smoke passes). **CentiColon** advisory R line on every `--check` (1395-n7qd/88tp/ue3i; R=1409, 0 satisfied until litmus steps name req-ids — 1395-64r7 next). **Lua runtime foundations**: `json get`/`yaml get` answer the jq subset (1375-rn9b), `hash sha256`/`time now` verbs (1375-8g5t), the litmus runner reads its own metadata without jq/yq (1375-6pnd), jq ratchet 365→344 (1375-2x4e), `json get --help` names its subset (1401-bcd7). **Release integrity**: every upload job gated per job incl. the macOS job that had none (1406-9ctt); manifest bytes re-hashed and cosign identity wired, proven against the runner's cosign v3.0.5 on the real v56.9.25.2 bundles (1407-6jr8). | **macOS**: every Mac gate and pre-build litmus deleted `/Applications/Tillandsias.app` and killed the tray (1401-p3k7); two Mac gate reds fixed (1411-b5fk sandbox `/var` alias; hardware-fingerprint cwd-relative binary, bash-3.2-safe). **Vault**: a delivered Shamir share is validated before persisting, without opening a wipe path (1200-ih38). **Lua sandbox** refuses unresolvable paths, fail-closed (1412-n5cp). `drain-queue.sh` refuses a bare run instead of launching a paid agent (1404-4x3r). Attestation checks containment, not equality (1110-4v4h). Deciders see untracked files (1391-8ikx); added fixtures run in the Mac regime (1401-x76w); bash-3.2 case-in-`$( )` rule (1413-8bee). Grader refuses a wrong-dimension index (1258-u8re); stale project-info server detectable (1414-mjdw); locale-safe dashboard (1191-vrjf); three env-var test races (1415-nvzz/89bs); selector host self-exclusion (1420-9jdf). |
| v56.9.25.2 (**STABLE** — promoted 2026-09-26T06:0xZ by the macuahuitl coordinator on the operator's direction ("do a daily cut, run the tests, and promote to stable") on three curl-install reports for this exact tag: Linux PASS on lenovinha (1371-a7w2 closed on it: `--reset-state` printed `keychain:vault-shamir-share-v1 (already absent) keychain:vault-root-token-v1 (already absent)` twice, exit 0, reprovisioned), Windows PASS on yolanda (no memory reaps on the new 8 GB WSL swap), macOS §1–§3 PASS on macbookair (cosign verified) with §4 forge lane UNFINISHED at a 3 h cap and not claimed by this promotion (1385-h6uz); promoted with `promote-stable.sh --force` because its evidence matcher needs PASS and the version on ONE line and two reports split them across title and verdict lines, a matcher gap recorded as a finding, not missing evidence) | Operator-authorized daily cut (2026-09-25), shipped as the fix-forward of **v56.9.25.1**, which was tagged but never published (its Linux job failed four times on one cache.nixos.org NAR that the runners' CDN edge truncated at 2 MiB; zero code delta between the two, and the release workflow gains nix `http2 = false` + `fallback = true`, 1272-95ng). Carries 104+ linux-next commits past v56.9.23.1, including the embedded-Lua archiver apply path (e4385b28a) and the land tool pushing HEAD (1366-d5v2). | **Linux `--reset-state` refused on every clean host** (1371-a7w2, reported by the operator from calmecacpilli): an absent keychain entry ("No matching entry found in secure storage") was scored as a failure after `podman system reset` had already run, leaving the host wiped and unprovisioned; the keyring `NoEntry` variant now reads as already-absent. GPU container start names its cause (1248-j6vd); reset_state env tests serialized (1369-a76a). Known, shipping with it: the unstable-URL installer still defaults to STABLE (1369-sjbc, fixed on trunk after this cut; set the channel explicitly). |
| v56.9.19.1 … v56.9.23.1 (6 releases, **DISTILLED** 2026-10-08 — see the policy below; v56.9.19.2 was **STABLE**: promoted 2026-09-20T08:59Z on three curl-install PASS reports (Linux pirria, macOS macneo, Windows yolanda), superseded as stable by v56.9.21.1) | The post-restart series, cut 2026-09-19 → 09-23. **Fleet flow**: the install reset contract on all three platforms (`--reset-state`; 1286-4437), join-the-fleet and initialize-bare-metal-host skills, the plan binary judging its own currency by an embedded content hash (1287-h6qn), `./build.sh --preflight` (1305-udgs, macOS-capable 1352-vmbc), the `work/<order>` lane and the landing queue that adopts a green gate across plan-only moves (1315-4a7j, 1316-bnzt, 1335-2nzf), tier-selector slice 1 (765-xpct), the litmus verdict grammar (1309-fhxb). **Product**: cloud-only project lifecycle, host checkout mount and mirror-to-host sync retired (591-x7ws, 1338-x5rq); tray menu order fixed for gnome-shell; the macOS tray embeds its Ionantha icon instead of showing "T" (1367-irnh) and the Windows EXE carries a multi-size icon with per-phase tray icons (1335-jz8c); cosign arrives verified or not at all (1324-ujvb); the credential guard asks the secret store before `gh` (1347-r9g8). v56.9.19.2 was a zero-code-delta fix-forward staging the router sidecar for the Windows tray job (1171-ccf2). | Release-tier-only fixture reds fixed before each cut (1354-dw8x, 1337-3tk6, 1357-trtz); the executable-bit assertion and salvage restore (1321-2ixp); BSD `date` %3N (1013-qv7c); subuid-owned vault-data (1284-jf86). Known at the time: installers from the unstable release installed STABLE without TILLANDSIAS_CHANNEL=unstable (1369-sjbc); the signature path was not exercised by any smoke and install-windows.ps1 had no cosign call site; the WSL guest-shape warning threshold was refuted on yolanda (1339-r9xv). Smokes: macOS and Windows PASS on v56.9.22.1, macOS icon PASS on v56.9.23.1. Full per-release detail: these rows in git history before this distillation (README.md at 1383930fc). |
| v56.9.11.1 … v56.9.13.1 (4 releases, **DISTILLED** — see the policy below; two were **STABLE**: v56.9.12.2 promoted 2026-09-12T10:52Z on three-platform smokes (macOS cold curl-install of the CI-built tray on macbookair, Windows Ready in 38 s on yolanda, Linux §1-§3 on cachyos with its operator's consent), and v56.9.13.1 promoted 2026-09-16 by flag flip rather than a fresh cut (952-mrsl) after curl-install PASS on esmeraldinha, pirria and macbookair, shipping two named defects: 1171-ccf2 (the Windows zip lacked `tillandsias-headless.exe`) and 1215-xazj (the tray's `--github-login` resolved its repository from the guest's CWD). v56.9.11.1 published Linux + macOS only (the Windows job failed, 1122-xi2f) and v56.9.12.1 was its Windows rebuild) | Host-checkout elimination for cloud launches (776-jcf3), the ephemeral-guarantee spec, the ledger-write reachability gate step (1080-4deb), sub-agent and token budget rules in both skills (1119-6wn6); the Windows tray placeholder check covering exactly the embedded arch (1122-xi2f), the fragment-status-loss guard understanding a reopen after falsification (ac0ea1089), the plan-only push lane refusing what it cannot fold (1124-7f3u), the 1115-yvrq selector fix; the host↔guest control-wire PSK keyed to the guest binary's digest known at tray build time on macOS and Windows, with the unkeyed entry point refusing on release (1084-x8ya); the fleet-restart hardening window (2026-09-12/13): the documented Linux reset clears the host-held Vault credentials (900-z3kv), the land tool retries a push once after an auth blip and never re-auths (1164-cftu), the loop's token counter (1119-6wn6), the stale-ready-row pass (1144-jfr5), the competing-gate detector (1141-vf9w, 1150-q462), the de-slop protocol as a skill (829-dkuc), capability envelopes that name measured vs served (1139-xe5m), the Windows probe refusing a stale binary by vocabulary (1172-dyvd), the capability-row guard no longer failing open on age (1154-8ywc, 1165-xkjh), the Silverblue depsolve-skew probe (1165-g6wx), `clamp-ca-material.sh` clamping on BSD stat (1135-z8gn), the browser enclave host-network default (1118-dwgx). | Forge tmpfs mode and the finalize-cycle exec bit (440cde994, 1116-vps5); committable-branch fixture identity (1109-t8kw); the ripgrep path-operand hang (d15aaf3d4); the metrics split guard (1096-p3tn); the land-script push bounded with a named refusal (1131-iax2); Windows-lane defects 1127-apa8/1128-4ffr/1129-xm5z and the Windows gate as root (1129-3yv7); env-var test races in the headless crate (1146-z8ux); the salvage net's gaps (1146-8j7i, 1148-3439); compaction reading one LWW channel and its blind coverage guard (1156-eif4, 1157-ghmi, 1158-y3ad); the credential-helper host pin versus its fixture (1161-42pc, 1118-bscs); the dead-env detector's four blind spots (1166-99mk…1169-zw44); the reaper's SIGPIPE-under-pipefail flake (1076-kft9 class); ten fixtures restored to mode 755 after landing 644 from Windows; the cheatsheet tier check (1140-d6ni). Known and filed while shipping: 1119-w2rj, 1119-9yjk, 1120-s3e5, 1122-6sqz, 1127-xm3m, 1134-u934 (`tillandsias-vault` SIGKILLed on every shutdown), 1159-g96c. |
| v56.8.31.3 … v56.9.5.1 (4 releases, **DISTILLED** — see the policy below; two were **STABLE**: v56.8.31.3 promoted 2026-08-31T22:20Z on yolanda's first fully unattended blessing round from downloaded assets, and v56.9.2.1 cut and promoted 2026-09-02 unattended, operator-authorized while asleep; v56.9.4.1 needed four gate attempts after 1022-y7kc's thirteen host-state and instrument causes; v56.9.5.1 was the union-litmus 291/291 cut) | **milestone: v0.5 opened.** The version scheme went epoch-anchored (operator ruling 2026-08-31): `<years_since_epoch>.<month>.<day>.<build>` replaces `Major.Minor.YYMMDD.Build`, every comparator resolves at field one so no tag rewrite or flag day, `--bump-minor` retired, milestones moved to the plan ledger's `desired_release` buckets; the MSIX encoder retired with it (776-g6r3) and all three Store submission blockers closed. Fail-loud diagnosis: dev-inference exit(2) root-caused to the 128-pids ceiling (811-28eh); the litmus runner's kill-time adjudicator diffs its own cgroup pressure and 36 hidden tests execute (956-llei); ghost-trace gate over yaml and markdown (867-vd4z); a hardware fingerprint that refuses an untrue twin claim (805-r98w); login checks authorization, not only authentication (759-vceg — later reversed by the 1217-54vw ruling). Hardware placement: the AMD Vulkan lane places (520), accel envelopes side- and engine-qualified (793-*), the capability matrix keyed on (fingerprint, substrate) with the Windows probe seeing the NPU, the tier's model warmed at forge start (965-hz3f); `--ensure-enclave` (1004-xw3q); guest vsock relay to host-native services (830-xsk2); guest binary staged off ~/src (1019-ivia); cycle metrics naming repeated and skippable steps (1001-q3zf); identifiers for all 653 spec requirements and the obligation lattice enforced in code (976-suab, 977-*); every workspace crate's tests through the gate ratchet (1003-444f). Tray honesty on every platform: macOS `--diagnose` prints the recorded verdict with its source and age instead of "healthy" (980-ja2m), the Windows guest health line says how old it is (1032-utne), LocalProjects wire surface removed and WIRE_VERSION 3 pinned against literals (997-e4v2, 1029-5wvd); project-label validation fails closed on an empty enumeration at all four sites (1031-q4pb, security); a failed forge launch never wedges the next or kills a live sibling (873-vgyg). | Three cuts to get v56.8.31.x clean: v56.8.31.1 shipped zero Windows assets because the unsigned-MSIX withhold guard rewrote `SHA256SUMS-windows` with CRLF (yolanda, f77897371); v56.8.31.2's first dispatch died at HTTP 422 on a literal CR byte the coordinator's heredoc embedded in the CR-invariant's own comment, and its Windows job at `msix-version-unmappable` because the cutover's Windows half existed only on one host — a green that does not name which artifact it verified can be true and useless. v56.9.2.1: lane socket listener never bound by the live launcher; seven pids-limit sites aligned (959-fpc5); three born-red litmus repaired; vault self-heal asks the key it just unsealed with (803-49re). v56.9.4.1, 73 fixed orders: headless shutdown SIGKILLed unowned containers (1019-ba6e); `podman rm` satisfied the enclave health check (1004-inkc); a grep-shaped fixture that could not fail (1021-a944); the credential guard green on file presence and blind on macOS (988-7kxf); present-but-unusable accelerators made the bring-up lane (1002-7jeg); the smoke runbook's PIPESTATUS-under-zsh (1004-fue3). v56.9.5.1: the two tray crates shared a [[bin]] name so a workspace gate ran the wrong platform's stub (1043-kvvn); the freshness-inventory walk 18 s → 0.7 s on ext4, 13.5 s on drvfs — the headline number does not travel (1038-d7vw); cheap deciders hoisted ahead of the compile (1009-gccx); three vacuous tray absence asserts (1028-3eiz). Known open through the series: the operator's gh tokens revoked server-side on three hosts with no mechanism found (1025-a896), the host-class build tune-ups (1047-h88p). |
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
