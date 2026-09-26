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
| v56.9.25.2 (daily) | Operator-authorized daily cut (2026-09-25), shipped as the fix-forward of **v56.9.25.1**, which was tagged but never published (its Linux job failed four times on one cache.nixos.org NAR that the runners' CDN edge truncated at 2 MiB; zero code delta between the two, and the release workflow gains nix `http2 = false` + `fallback = true`, 1272-95ng). Carries 104+ linux-next commits past v56.9.23.1, including the embedded-Lua archiver apply path (e4385b28a) and the land tool pushing HEAD (1366-d5v2). | **Linux `--reset-state` refused on every clean host** (1371-a7w2, reported by the operator from calmecacpilli): an absent keychain entry ("No matching entry found in secure storage") was scored as a failure after `podman system reset` had already run, leaving the host wiped and unprovisioned; the keyring `NoEntry` variant now reads as already-absent. GPU container start names its cause (1248-j6vd); reset_state env tests serialized (1369-a76a). Known, shipping with it: the unstable-URL installer still defaults to STABLE (1369-sjbc, fixed on trunk after this cut; set the channel explicitly). |
| v56.9.23.1 (daily) | Operator-requested cut to verify the tray icon fixes on a published build. **macOS tray icon**: the tray embeds its Ionantha PNG (via `tillandsias_core::icons::tray_icon_png`, 18pt, template image) instead of reading `tray-icon.png` from disk (1367-irnh). The old lookup went one directory too high from `Contents/MacOS`, so EVERY CI-built tray showed the letter "T", including a normal install in /Applications (measured on v56.9.22.1 by macbookair). **Windows tray icon**: `build.rs` renders the Ionantha SVG into a multi-size `.ico`, embeds it as the EXE's Win32 resource (Start-menu and taskbar icons follow it), and swaps the tray icon per VM phase (1335-jz8c). **Tray menu**: the cloud menu is agents first, then projects, so a project list opens near the top of gnome-shell's popup instead of being unreachable (operator request). **Lua predicates**: the Cacheable class is an allow-list, so a cached verdict cannot read the clock or the disk (1367-upz6). **Process**: join-the-fleet arms the host's own session slot and stays resident; packet-discipline rules (a WIP limit, finish before starting, close what landed); the compaction renderer no longer re-quotes block-scalar lines. | Litmus reds only the release tier sees, fixed before the cut: the binding-truth fixture's scratch tree lacked spec files after 1356-vv5m, so its mutation arms read an unrelated refusal; two litmus files pinned literal fixture totals (5/5, 12/12) that a grown fixture or a named skip breaks (1357-trtz). Relayed tray refs reached origin failing rustfmt and clippy. The release runbook's bump-branch gate must run with the class selector off, since a scoped stamp cannot push a new branch. NOT IN THIS RELEASE: the land tool's branch-mismatch fix (1366-d5v2) and its race-classification follow-up landed after the tag; 1360-jjyx (non-interactive reset remedy on macOS) is still open. **SMOKES:** macOS 1b PASS on macbookair: install-macos.sh to /Applications, in_app=true, and the status item's title is empty (an image is set) where the v56.9.22.1 control on the same machine read "T" (report `plan/issues/smoke-e2e-findings-v56.9.23.1-2026-09-23-macos-macbookair.md`). KNOWN: every installer downloaded from the unstable release installs STABLE unless TILLANDSIAS_CHANNEL=unstable is set, so this daily is reachable only with the variable or a pinned base (1369-sjbc). **VERIFY ON THIS TAG (operator's eyes):** the macOS icon in a light AND a dark menu bar (1367-irnh 2b), the Windows tray/Start-menu/taskbar icons and per-phase tray icon (1335-jz8c; the published tillandsias-tray.exe carries the new Ionantha icon and the Start-menu link points at it, verified by yolanda, but no screen was readable), and whether gnome-shell grows the popup for an agent row's project list. |
| v56.9.22.1 (daily) | Cloud-only project lifecycle, decided by the operator on 2026-09-22 ("remove the host checkout remainders"): the opt-in forge host mount and the mirror-to-host working-copy sync are retired, and the tray's cloud project list is flat by default with paging opt-in behind `TILLANDSIAS_MAX_CLOUD_MENU_ITEMS`, measured against a real menu rather than inferred from the DBusMenu protocol (591-x7ws, 1338-x5rq). The Linux tray puts the project list LAST, because gnome-shell expands a submenu inline and an expansion anywhere else pushes the footer off the fold; the id set stays identical on all three surfaces. The Windows installer now reports the WSL guest shape a `.wslconfig` will produce, names a known-bad ratio with the operator's own numbers beside the measured failure, warns that `autoMemoryReclaim` under `[wsl2]` is inert, and never writes the user's file (1339-r9xv). `cosign` arrives verified or not at all: the pin gates EXECUTION and sigstore gates TRUST as two separate refusals, the anchor is the release's own signed checksum manifest, the asset is selected by platform, and a binary that cannot execute here answers `could-not-run` rather than a signature failure (1324-ujvb). The mirror's startup sweep now says WHY a stranded tag is expected: the pre-push refspec is heads-only, so upstream tag moves never reach a mirror and a cut leaves `latest`, `stable` and `unstable` stale BY DESIGN rather than as a fault (1350-ku7v). A report-only census of self-flagged unverified premises, with git-blame ages, never a gate (1349-tdpg). | The credential guard asks the secret store BEFORE starting `gh`, so a probe can no longer manufacture the state it reports, and a probe killed mid-read answers `unknown` rather than asserting the credential is absent — whose remedy would evict the fleet's token (1347-r9g8, 1025-a896). Two fixtures reported an EMPTY verdict at rc=0 because their scratch trees lacked a script the helper resolves from the tree root, and the arm captured the refusal into silence; both reds were invisible to every routine gate and only the release tier could see them (1354-dw8x, 1337-3tk6). A `test -x` assertion now counts as requiring the executable bit, taught to the decider's sweep as well as its filter, and the salvage tool restores the bit at snapshot time so a Windows-origin snapshot cannot carry the defect (1321-2ixp). The landing queue ADOPTS a green gate when trunk moved by plan fragments only, instead of discarding a 21-minute gate (1335-2nzf). `./build.sh --preflight` runs on macOS at all, where it exec'd `setsid` unconditionally and reported every guard as a refusal, and a guard that declares it could not ask is no longer scored as one that refused (1352-vmbc, 1354-apns). NOT IN THIS RELEASE, verified by reading the tag rather than the branch: the five-category verdict that refuses to vouch for guards which never examined the tree is 1353-ryhq and had not landed at the tag; and the mirror's sync-state PUBLISHER, while present in the source tree as `images/git/publish-sync-state.sh`, is not COPYed into the mirror image and has no call site in `entrypoint.sh`, so a mirror built from this release publishes NOTHING and `ls-remote` for `refs/tillandsias/sync-state/*` returns empty — the lifecycle that runs it arrives later (1350-ku7v). SMOKE SCOPE, measured after the tag and recorded here because the row is what a later reader opens: macOS PASS (install, destructive reset, reprovision) and Windows PASS. The SIGNATURE path was not exercised on either, and the three lanes differ and are not collapsed — on Windows cosign is absent AND the shipped install-windows.ps1 contains NO cosign call site in this release or the previous one, read from the downloaded artifacts, so the signing side shipped while the verifying side has no consumer on that platform; on macOS cosign is absent and the installer made no verification attempt; on Linux cosign is absent and the installer's behaviour on this point is established by nobody. What the installers do check is the SHA256 manifest, which is not a signature check. Also unmeasured and now refuted by the host it was written for: the WSL guest-shape warning's 700 MB-per-vCPU threshold fires on a configuration measured good, 512 MB per vCPU having completed a 112-minute gate on that host, and recommends a config byte-identical to the one in force (1339-r9xv, found by running the shipped installer). Every gate step must carry a recorded second-regime run before it enters the gate (1302-7j8p). The missing-agent refusal names the invocation rather than the file alone, so running the remedy works (1351-y98c). The capability probe derives a proven container lane per device from its own render node (1254-47xd). |
| v56.9.21.1 (daily) | The work-ref lane (1315-4a7j, operator direction 2026-09-20): `work/<order>` is where a host commits and pushes, ungated, as often as it likes; every hook and land refusal carries the complete affordance (`prefer work branches …`), and `scripts/check-landing-provenance.sh` measures how integration arrives so enforcement is a later decision on a number. The landing queue (1316-bnzt): `scripts/land-queue.sh` lands one open PR at a time into linux-next, every candidate at FULL until the tier selector activates. The skills teach it (1317-9ugn): join-the-fleet §3 states the flow in one order (claim → work ref → push freely → draft PR → the queue lands once → close with the LANDED SHA), a worker's slot is `check-fleet-membership.sh` then `/advance-work-from-plan`, `rerere` is a requirement, the front door is in §6. The tier selector, slice 1 (765-xpct, approved 2026-09-20): `scripts/change-class.sh` — tiers are ALLOW-LISTS and a file that decides what runs is FULL — wired to nothing yet. The litmus runner's verdict grammar (1309-fhxb): `skip:` and `advisory:` are terminal verdicts, a test is judged by its steps, `Test Verdicts:`/`Step Verdicts:` lines, not-run outside the rate. Guest staging refuses a wire-less guest at staging time and reads strings without `strings` (1308-9ej7). The mirror's ssh lane mounts its signer secret from the right target (1313-prin). | FIX-FORWARD FOR v56.9.20.1: the headless parser's flag allow-list lacked `--reset-state` and `--reset-guest`, so the published installer exited 2 at §1 on every Linux host (1286-4437; a fixture now RUNS the binary and a unit test pins the allow-list to the dispatch). A push made only of salvage refs was classified as the work lane, turning the salvage-deletion refusal (874-w2gc) into a warning — caught by the pre-cut litmus, never shipped (1315-4a7j). The diff-scoped sigpipe guard missed the and-or spelling and printf-of-a-variable producers, either alone enough to hide 1306-ifhv; it now flags bounded code on purpose with `# sigpipe-ok:` or `<<<` as the escape (1307-ermc, contract change measured at 9 new lines in 7 days). The macOS reset announcement states observation, not intent; the doubled colon; `--diagnose`'s exit 2 no longer reads as an unknown flag (1286-4437, macneo). `test-salvage-audit.sh` captures then matches (1306-ifhv). A litmus binding must sit under a spec its file declares (1304-wbb2). `restage_blocker` asks the nix lane's capability, not `command -v nix` (790-mbk9). BSD `date -v` needs an explicit sign in the fragment-ts-skew fixture. Smokes of v56.9.20.1: Windows PASS (first proof of the reset contract on a published artifact), macOS PASS, Linux FAIL at §1 — the defect this cut carries the fix for. **SMOKES (v56.9.21.1):** Linux PASS on pirria (the allow-list fix accepted on the published artifact: `install_exit=0`, zero `Unsupported option`; reset contract measured against a banked pre-state; 5/5 row claims; signatures unverified — cosign absent, 1324-ujvb), macOS PASS on macneo (four claims on the shipped artifact; the announcement states observation; mtime-vs-run_start with nvram.bin as the control), Windows PASS on yolanda (curl-install 17:03–17:05Z by wall clock, sha256 verified; the destructive reset cleared and re-minted both vault credentials for the first time on a published artifact, vm-uuid preserved; reprovision to Ready; `--diagnose --json` run last, exit 0, guest 56.9.21.1; 27 memory samples, no reap, floor 44.7% free; report `plan/issues/smoke-e2e-findings-v56.9.21.1-2026-09-21-windows-yolanda.md`). **All three platforms PASS on the exact tag: stable-eligible (888-p3kt); the operator directed promotion on 2026-09-21 and it follows this row.** **KNOWN, FILED, SHIPPING:** a contended VM start on macOS reports "The boot loader is invalid" and names neither the holder nor the contention (1253-gina's pre-fix behaviour, reproduced on macneo against this tag; the explainer landed on trunk at 576b17c95 after the cut and rides the next daily); `--reset-state`'s `TILLANDSIAS_DESTRUCTIVE_RESET_OK=0` runtime path is untested on Linux (it provisions); the cold-state probe answers about the past with only the present (pirria's packet). |
| v56.9.20.1 (daily) | The install reset contract on all three platforms (1286-4437, operator ruling): `--reset-state` destroys local state, preserves the installation identity, announces before touching anything, reprovisions synchronously, and every installer calls it by default (`TILLANDSIAS_DESTRUCTIVE_RESET_OK=0` is the one opt-out; the macOS arm carries an ungated-module guard). Two operator-directed skills: `./skills/join-the-fleet` (idempotent onboarding for bare metal and forges with a non-mutating checker) and the standalone, self-evolving `./skills/initialize-bare-metal-host`. The plan binary judges its own currency by a build-embedded content hash (1287-h6qn; the mtime ladder's fail-open closed). `./build.sh --preflight`, a front door that runs every guard that can refuse a push in one command, budget measured (1305-udgs). The mirror ssh push lane fails closed when unwired (1309-qc95) and its server half is wired (1313-prin link 3: a per-mirror Vault identity, signed host cert, sshd) — default-off, client half pending, not yet the credential-free push. Hand-written fragment timestamps in the future are refused at the lane (1313-w78k); timing records carry their checkout root (1299-s2sv); the macOS guest-to-host vsock inference closure is a re-runnable post-build fixture (830-xsk2) on a Rust seccomp derivation; `--parse-only` loads the document before extracting (1303-2d5g); Windows install regains its post-install diagnose (1258-8wfb); the gnome-keyring Locked probes are removed (1265-8qr6, upstream bug). | The MSYS pre-push hook's per-file spawn (an 18-minute "hang") and the status-loss checker's three calls per fragment (1307-kic6); set-field consuming the next option as a value (1285-vz27); the signature fixture's digest tool (1273-4mak); the metrics-log resolver on worktrees (1268-m2ir); a producer failing into a filter now reaches the litmus verdict (1293-wka4); the ci-release arm that counted a fixture's mention as a second opt-out (1286-4437); `tail -1` discarding a failing arm (1269-gfdi); the cache-root global read (1282-rkkm); executable bits lost to an inode-replacing rewrite (731-d89b); the locked-vs-absent keyring discriminator rebuilt (1189-2ra5). KNOWN at cut: the runner's `--list` prints no suites (1318-3dgq, open); the ts-skew fixture is inert on macOS pending a one-character `date -v` sign fix; link 3's AppRole mount collision (fix gated, lane default-off); the runner's skip/advisory grammar (1309-fhxb) lands next. **DEFECT (Linux curl-install, measured by pirria's smoke 2026-09-21):** the headless parser's flag allow-list (`known_flags` in crates/tillandsias-headless/src/main.rs) lacks `--reset-state` and `--reset-guest`, so `install.sh` exits 2 at its `--reset-state` step on every Linux host; the macOS and Windows trays are unaffected (the Windows tray lists the flag; the macOS tray has no allow-list). Windows and macOS smokes PASSED. Superseded by the fix-forward cut; never repaired in place. |
| v56.9.19.1 … v56.9.19.2 (2 releases, **DISTILLED** — see the policy below; v56.9.19.2 was **STABLE**: promoted 2026-09-20T08:59Z by the macuahuitl coordinator on three curl-install PASS reports (Linux pirria, macOS macneo, Windows yolanda), then confirmed by post-promotion stable-channel smokes on all three; superseded as stable by v56.9.21.1) | v56.9.19.1 was the first cut after the 2026-09-18 fleet restart (BigPickle's NPU/iGPU/GPU passthrough layering on the Silverblue hosts; gate a COMPOSED verdict after five `--ci-full --install` runs, and the operator ruled to ship with one known red). Its release run shipped no Windows tray, so v56.9.19.2 was a ZERO-code-delta FIX-FORWARD: the Windows tray job stages the published router sidecar before building (1171-ccf2, 723-wd8i); run 35459238928 green on all three jobs, 32 assets. | Findings filed from these cuts: a Windows-target headless compile demanding a Linux musl artifact; the hardcoded x86_64 sidecar pattern; one MSIX version for two same-day packages; install-macos.sh logging `channel: stable` for a pinned prerelease (1280-58kq); BSD `date` lacking %3N (1013-qv7c); the subuid-owned vault-data the clearer could not remove (1284-jf86). The forge-lane NO VERDICT on the Console rate limit and the gnome-keyring crash (upstream, gnome-keyring #195) were both resolved after promotion. Full evidence: the v56.9.19.x rows in git history of this file and plan/issues. |
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
