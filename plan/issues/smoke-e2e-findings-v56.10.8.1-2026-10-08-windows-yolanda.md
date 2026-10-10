# Smoke E2E findings â€” v56.10.8.1, Windows, yolanda (2026-10-08)

Coordinator smoke packet (2026-10-08): an end-user curl install of the exact
prerelease tag, its reset leg, and an end-user reading of the install output.
Destructive runs were allowed by the operator (2026-10-08). Host: yolanda-windows,
Windows 11 Home 10.0.26300.9457, WSL 2.7.13.0, 15.2 GB RAM.

## Verdicts

| Leg | Verdict |
|---|---|
| 1a curl install of the tag, `--version` == 56.10.8.1 | **PASS** â€” `tillandsias-tray 56.10.8.1 (1383930fc)` |
| 1b SHA-256 manifest | **PASS** â€” `sha256: ok (54836fc8590bbd31f8d01df270929f56ef2d5c5b85069c4def29a93f18de7174)` |
| 1c cosign | **FAIL (not attempted)** â€” the installer printed no cosign or signature line at all, although the release ships `.cosign.bundle` for every Windows asset |
| 1d guest ready (installer's own reset) | **PASS** â€” `[reset-state] RESULT: VM Ready - control wire up` and Vault `initialized:true sealed:false` |
| 1e first tray launch after install | **FAIL** â€” `WSL recipe provisioning failed: control-wire handshake did not succeed within budget: credentials delivery failed: DeliverCredentials was received but not accepted: superseded by a newer in-guest handover`; launch-failure bundle written |
| 2 reset leg | **FAIL vs the packet's expectation** â€” this release's `--reset-state` is still the old HARD body (S1 #243 lands after this cut): distro, Vault store, both vault credentials and the download cache destroyed |
| 3 end-user output | **FAIL** â€” 561 lines printed, almost all technical (inventory below) |

## Leg 1 â€” install

Command (stdin not a console, so the two remaining prompts take their defaults):

```
$env:TILLANDSIAS_VERSION = '56.10.8.1'
irm https://github.com/8007342/tillandsias/releases/download/v56.10.8.1/install-windows.ps1 | iex
```

Exit 0 after 146 s. Before: tray 56.9.27.2 (52e3bc32e). After: `tillandsias-tray 56.10.8.1 (1383930fc)`,
guest_version 56.10.8.1. `--diagnose --json` exited **2** and the installer carried on (`diagnose:
version=56.10.8.1 commit=1383930fc (--diagnose exit 2)`). The cause of exit 2 was not investigated.

## Leg 2 â€” reset (what survived, what was rebuilt, sign-in)

| | before | after |
|---|---|---|
| distro disk (ext4.vhdx CreationTime) | 2026-09-26T02:05:31Z | 2026-10-08T23:23:05Z â€” **re-imported** |
| Vault store `core/_keyring` sha256 | `b1681743dc0779fb` (74 files) | `6f14a8a1c7239769` (76 files) â€” **new store** |
| download cache listing | `5E2FA5C95EE14673` | `7F911F605E711186` â€” **removed and refetched** |
| Credential Manager | `tillandsias-vm-uuid` (share and token already absent from an earlier HARD test on this host) | `tillandsias-vm-uuid` only â€” **share and token never written back** |
| `tillandsias-vm-uuid` | present | present (preserved) |

Sign-in: the Vault store was destroyed, so every sign-in it held is gone and a user signs in
again. (This host held no sign-in before the run, so no login was lost here; the destruction is
the evidence.)

**The defect behind 1e (filed as its own row):** after the reset clears the host's vault
credentials, the re-provisioned guest creates its own handover. The tray delivers credentials,
the guest answers `DeliverCredentialsOutcome::Superseded` (890-y72v: "a fresh handover was
already pending ... the remedy is for the host to re-read, not re-deliver"), and
`crates/tillandsias-windows-tray/src/installation_uuid.rs` `deliver_credentials_and_check_handover`
returns `Err` on ANY non-`Accepted` outcome BEFORE it calls `GetVaultHandover`. So the handover is
never read, Credential Manager is never repopulated, the tray retries with back-off (18
`superseded` lines in tray.log by 23:28Z) and gives up with a launch failure. Every install over
an existing install runs this reset, so every such first launch is exposed.

Also found: the operator's real Credential Manager holds a leaked test credential,
`tillandsias-vm-uuid-test-1119fd3d-31a6-4c4b-8616-f2fdf5746d74`, left by some test that did not
clean up. Not touched.

## Leg 3 â€” technical lines an end user sees (fixture input for 1561-47a8)

Of 561 lines, by category (line numbers in the transcript below):

- channel and source: `resolved-channel: stable (default of this installer copy) base: <url>` (2), `Pinned to v56.10.8.1` (13)
- host shaping: `wsl-shape: guest will take 16 vCPU(s)...` (3), `wsl-swap: ...` (4-6)
- paths: `Install path: ...` (11), `Extracting to ...` (20), `capability probe binary: ...` (21), `Start Menu shortcut: ...` (22), `Backing up existing install to Tillandsias.bak...` (19)
- download and integrity: `Fetching SHA256SUMS-windows...` (14), `Asset: <zip>` (15), `Downloading <url>...` (16), `Verifying SHA-256...` (17), `sha256: ok (<hash>)` (18)
- self-check: `Verifying installation via --version...` (23), `tillandsias-tray 56.10.8.1 (1383930fc)` (24), `Verifying install bits via --diagnose --json...` (25), `diagnose: version=... commit=... (--diagnose exit 2)` (26), `host: OS=...; WSL=...` (27)
- reset plan and flags: `Resetting local state and reprovisioning (--reset-state)...` (29), `preserved:` / `destroyed:` (30-31), `set TILLANDSIAS_DESTRUCTIVE_RESET_OK=0 ...` (32), the tray's `[tillandsias] --reset-state:` plan with `WILL BE DESTROYED` / `PRESERVED`, credential target names and `Skip the reset with TILLANDSIAS_DESTRUCTIVE_RESET_OK=0` (33-41)
- Windows tool noise: `The operation completed successfully.` x3 (42, 43, 534)
- `[reset-state]` lines: 108, of which **101 are rootfs download progress at 1% steps**
- package manager output from inside the guest: **~369 lines** (dnf transaction tables, `[ n/146] Installing ...`)
- phase lines `<phase>: pending|working|done (overall N%)`: 17
- launch: `Launching Tillandsias (WSL2 provisioning = --init will run automatically)...` (550), `(Right-click the icon for the menu; provisioning runs in the background.)` (552), the `PENDING ACTIONS` banner (554-559)

#247 (S3) and #252 (1561-47a8) already remove the reset-plan, flag, channel, self-check and
reset-log echo lines from the installer; this run is the pre-fix evidence. Not yet covered by any
row: the rootfs per-percent progress, the guest package-manager output, `The operation completed
successfully.` and the paths block.

## Transcript

```
== smoke: irm https://github.com/8007342/tillandsias/releases/download/v56.10.8.1/install-windows.ps1 | iex   (TILLANDSIAS_VERSION=56.10.8.1; stdin not a console)
  resolved-channel: stable (default of this installer copy) base: https://github.com/8007342/tillandsias/releases/download/v56.10.8.1
    wsl-shape: guest will take 16 vCPU(s) of 16 and about 8 GiB of 15.16 GiB.
    wsl-swap: 107.6 GB free on the swap volume -> swap=16GB (8 GB floor; 16 at 100+ GB free, 24 at 200+).
    wsl-swap: present and kept: [wsl2] swap=8GB (tillandsias would use 16GB; left unchanged)
    wsl-swap: .wslconfig already has swap, swapFile, sparseVhd and autoMemoryReclaim; nothing to add.

  Tillandsias Installer
  =====================
  Target: Windows x64
  Install path: C:\Users\bullo\AppData\Local\Programs\Tillandsias\tillandsias-tray.exe

  Pinned to v56.10.8.1
  Fetching SHA256SUMS-windows...
  Asset: tillandsias-tray-56.10.8.1-windows-x64.zip
  Downloading https://github.com/8007342/tillandsias/releases/download/v56.10.8.1/tillandsias-tray-56.10.8.1-windows-x64.zip...
  Verifying SHA-256...
  sha256: ok (54836fc8590bbd31f8d01df270929f56ef2d5c5b85069c4def29a93f18de7174)
  Backing up existing install to Tillandsias.bak...
  Extracting to C:\Users\bullo\AppData\Local\Programs\Tillandsias...
    capability probe binary: C:\Users\bullo\AppData\Local\Programs\Tillandsias\tillandsias.exe
  Start Menu shortcut: C:\Users\bullo\AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Tillandsias.lnk
  Verifying installation via --version...
  tillandsias-tray 56.10.8.1 (1383930fc)
  Verifying install bits via --diagnose --json...
  diagnose: version=56.10.8.1 commit=1383930fc (--diagnose exit 2)
  host:     OS=Microsoft Windows [Version 10.0.26300.9457]; WSL=WSL version: 2.7.13.0

  Resetting local state and reprovisioning (--reset-state)...
    preserved: tillandsias-vm-uuid (the installation identity)
    destroyed: the WSL2 distro and its disk, the two host vault credentials, the download cache
    set TILLANDSIAS_DESTRUCTIVE_RESET_OK=0 to skip the destructive half
  [tillandsias] --reset-state: resetting local state before reprovisioning.
  [tillandsias]   WILL BE DESTROYED:
  [tillandsias]     - the WSL2 distro and its disk
  [tillandsias]     - vault-shamir-share-v1
  [tillandsias]     - vault-root-token-v1
  [tillandsias]     - the download cache
  [tillandsias]   WILL BE PRESERVED:
  [tillandsias]     - tillandsias-vm-uuid
  [tillandsias]   Skip the reset with TILLANDSIAS_DESTRUCTIVE_RESET_OK=0. This is the ONLY opt-out.
  The operation completed successfully. 
  The operation completed successfully. 
  [reset-state] no host-side vault credentials to clear
  [reset-state] removed download cache C:\Users\bullo\AppData\Local\tillandsias\cache
  [reset-state] state wiped - reprovisioning from scratch...
  Setting up Fedora Linux: pending (overall 0%)
  Downloading Fedora rootfs: pending (overall 0%)
  Downloading Tillandsias: pending (overall 0%)
  Installing Tillandsias: pending (overall 0%)
  Starting Fedora Linux: pending (overall 0%)
  Connecting: pending (overall 0%)
  Setting up Fedora Linux: working (overall 0%)
  Setting up Fedora Linux: done (overall 16%)
  Downloading Fedora rootfs: working (overall 16%)
  [reset-state] Downloading Fedora rootfs: 0/70170200 bytes (0%)
  [reset-state] Downloading Fedora rootfs: 704250/70170200 bytes (1%)
  [reset-state] Downloading Fedora rootfs: 1408762/70170200 bytes (2%)
  [reset-state] Downloading Fedora rootfs: 2113274/70170200 bytes (3%)
  [reset-state] Downloading Fedora rootfs: 2817786/70170200 bytes (4%)
  [reset-state] Downloading Fedora rootfs: 3522298/70170200 bytes (5%)
  [reset-state] Downloading Fedora rootfs: 4210426/70170200 bytes (6%)
  [reset-state] Downloading Fedora rootfs: 4914938/70170200 bytes (7%)
  [reset-state] Downloading Fedora rootfs: 5619450/70170200 bytes (8%)
  [reset-state] Downloading Fedora rootfs: 6323962/70170200 bytes (9%)
  [reset-state] Downloading Fedora rootfs: 7028474/70170200 bytes (10%)
  [reset-state] Downloading Fedora rootfs: 7732986/70170200 bytes (11%)
  [reset-state] Downloading Fedora rootfs: 8421114/70170200 bytes (12%)
  [reset-state] Downloading Fedora rootfs: 9125626/70170200 bytes (13%)
  [reset-state] Downloading Fedora rootfs: 9830138/70170200 bytes (14%)
  [reset-state] Downloading Fedora rootfs: 10534650/70170200 bytes (15%)
  [reset-state] Downloading Fedora rootfs: 11239162/70170200 bytes (16%)
  [reset-state] Downloading Fedora rootfs: 11943674/70170200 bytes (17%)
  [reset-state] Downloading Fedora rootfs: 12631802/70170200 bytes (18%)
  [reset-state] Downloading Fedora rootfs: 13336314/70170200 bytes (19%)
  [reset-state] Downloading Fedora rootfs: 14040826/70170200 bytes (20%)
  [reset-state] Downloading Fedora rootfs: 14745338/70170200 bytes (21%)
  [reset-state] Downloading Fedora rootfs: 15449850/70170200 bytes (22%)
  [reset-state] Downloading Fedora rootfs: 16154362/70170200 bytes (23%)
  [reset-state] Downloading Fedora rootfs: 16842490/70170200 bytes (24%)
  [reset-state] Downloading Fedora rootfs: 17547002/70170200 bytes (25%)
  [reset-state] Downloading Fedora rootfs: 18251514/70170200 bytes (26%)
  [reset-state] Downloading Fedora rootfs: 18956026/70170200 bytes (27%)
  [reset-state] Downloading Fedora rootfs: 19660538/70170200 bytes (28%)
  [reset-state] Downloading Fedora rootfs: 20365050/70170200 bytes (29%)
  [reset-state] Downloading Fedora rootfs: 21053178/70170200 bytes (30%)
  [reset-state] Downloading Fedora rootfs: 21757690/70170200 bytes (31%)
  [reset-state] Downloading Fedora rootfs: 22462202/70170200 bytes (32%)
  [reset-state] Downloading Fedora rootfs: 23166714/70170200 bytes (33%)
  [reset-state] Downloading Fedora rootfs: 23871226/70170200 bytes (34%)
  [reset-state] Downloading Fedora rootfs: 24575738/70170200 bytes (35%)
  [reset-state] Downloading Fedora rootfs: 25263866/70170200 bytes (36%)
  [reset-state] Downloading Fedora rootfs: 25968378/70170200 bytes (37%)
  [reset-state] Downloading Fedora rootfs: 26672890/70170200 bytes (38%)
  [reset-state] Downloading Fedora rootfs: 27377402/70170200 bytes (39%)
  [reset-state] Downloading Fedora rootfs: 28081914/70170200 bytes (40%)
  [reset-state] Downloading Fedora rootfs: 28770042/70170200 bytes (41%)
  [reset-state] Downloading Fedora rootfs: 29474554/70170200 bytes (42%)
  [reset-state] Downloading Fedora rootfs: 30179066/70170200 bytes (43%)
  [reset-state] Downloading Fedora rootfs: 30883578/70170200 bytes (44%)
  [reset-state] Downloading Fedora rootfs: 31588090/70170200 bytes (45%)
  [reset-state] Downloading Fedora rootfs: 32292602/70170200 bytes (46%)
  [reset-state] Downloading Fedora rootfs: 32980730/70170200 bytes (47%)
  [reset-state] Downloading Fedora rootfs: 33685242/70170200 bytes (48%)
  [reset-state] Downloading Fedora rootfs: 34389754/70170200 bytes (49%)
  [reset-state] Downloading Fedora rootfs: 35094266/70170200 bytes (50%)
  [reset-state] Downloading Fedora rootfs: 35798778/70170200 bytes (51%)
  [reset-state] Downloading Fedora rootfs: 36503290/70170200 bytes (52%)
  [reset-state] Downloading Fedora rootfs: 37191418/70170200 bytes (53%)
  [reset-state] Downloading Fedora rootfs: 37895930/70170200 bytes (54%)
  [reset-state] Downloading Fedora rootfs: 38600442/70170200 bytes (55%)
  [reset-state] Downloading Fedora rootfs: 39304954/70170200 bytes (56%)
  [reset-state] Downloading Fedora rootfs: 40009466/70170200 bytes (57%)
  [reset-state] Downloading Fedora rootfs: 40713978/70170200 bytes (58%)
  [reset-state] Downloading Fedora rootfs: 41402106/70170200 bytes (59%)
  [reset-state] Downloading Fedora rootfs: 42106618/70170200 bytes (60%)
  [reset-state] Downloading Fedora rootfs: 42811130/70170200 bytes (61%)
  [reset-state] Downloading Fedora rootfs: 43515642/70170200 bytes (62%)
  [reset-state] Downloading Fedora rootfs: 44220154/70170200 bytes (63%)
  [reset-state] Downloading Fedora rootfs: 44924666/70170200 bytes (64%)
  [reset-state] Downloading Fedora rootfs: 45612794/70170200 bytes (65%)
  [reset-state] Downloading Fedora rootfs: 46317306/70170200 bytes (66%)
  [reset-state] Downloading Fedora rootfs: 47021818/70170200 bytes (67%)
  [reset-state] Downloading Fedora rootfs: 47726330/70170200 bytes (68%)
  [reset-state] Downloading Fedora rootfs: 48430842/70170200 bytes (69%)
  [reset-state] Downloading Fedora rootfs: 49135354/70170200 bytes (70%)
  [reset-state] Downloading Fedora rootfs: 49823482/70170200 bytes (71%)
  [reset-state] Downloading Fedora rootfs: 50527994/70170200 bytes (72%)
  [reset-state] Downloading Fedora rootfs: 51232506/70170200 bytes (73%)
  [reset-state] Downloading Fedora rootfs: 51937018/70170200 bytes (74%)
  [reset-state] Downloading Fedora rootfs: 52641530/70170200 bytes (75%)
  [reset-state] Downloading Fedora rootfs: 53329658/70170200 bytes (76%)
  [reset-state] Downloading Fedora rootfs: 54034170/70170200 bytes (77%)
  [reset-state] Downloading Fedora rootfs: 54738682/70170200 bytes (78%)
  [reset-state] Downloading Fedora rootfs: 55443194/70170200 bytes (79%)
  [reset-state] Downloading Fedora rootfs: 56147706/70170200 bytes (80%)
  [reset-state] Downloading Fedora rootfs: 56852218/70170200 bytes (81%)
  [reset-state] Downloading Fedora rootfs: 57540346/70170200 bytes (82%)
  [reset-state] Downloading Fedora rootfs: 58244858/70170200 bytes (83%)
  [reset-state] Downloading Fedora rootfs: 58949370/70170200 bytes (84%)
  [reset-state] Downloading Fedora rootfs: 59653882/70170200 bytes (85%)
  [reset-state] Downloading Fedora rootfs: 60358394/70170200 bytes (86%)
  [reset-state] Downloading Fedora rootfs: 61062906/70170200 bytes (87%)
  [reset-state] Downloading Fedora rootfs: 61751034/70170200 bytes (88%)
  [reset-state] Downloading Fedora rootfs: 62455546/70170200 bytes (89%)
  [reset-state] Downloading Fedora rootfs: 63160058/70170200 bytes (90%)
  [reset-state] Downloading Fedora rootfs: 63864570/70170200 bytes (91%)
  [reset-state] Downloading Fedora rootfs: 64569082/70170200 bytes (92%)
  [reset-state] Downloading Fedora rootfs: 65273594/70170200 bytes (93%)
  [reset-state] Downloading Fedora rootfs: 65961722/70170200 bytes (94%)
  [reset-state] Downloading Fedora rootfs: 66666234/70170200 bytes (95%)
  [reset-state] Downloading Fedora rootfs: 67370746/70170200 bytes (96%)
  [reset-state] Downloading Fedora rootfs: 68075258/70170200 bytes (97%)
  [reset-state] Downloading Fedora rootfs: 68779770/70170200 bytes (98%)
  [reset-state] Downloading Fedora rootfs: 69484282/70170200 bytes (99%)
  [reset-state] Downloading Fedora rootfs: 70170200/70170200 bytes (100%)
  Downloading Fedora rootfs: done (overall 33%)
  Installing Tillandsias: working (overall 33%)
  [reset-state] ? Flattening Fedora OCI image...
  [reset-state] ? Installing systemd + podman in Fedora base...
  Package                          Arch   Version                      Repository                            Size
  Upgrading:
   audit-libs                      x86_64 0:4.2.1-1.fc44               updates                          390.5 KiB
     replacing audit-libs          x86_64 0:4.1.4-1.fc44               4111fdab6da64df386bf1b4cbc945426 390.5 KiB
   dnf5                            x86_64 0:5.4.6.0-1.fc44             updates                            3.4 MiB
     replacing Total size of inbound packages is 117 MiB. Need to download 117 MiB.
  After this operation, 428 MiB extra will be used (install 453 MiB, remove 26 MiB).
  [  1/129] dbus-common-1:1.16.2-1.fc44.n 100% |  23.6 KiB/s |  14.2 KiB |  00m01s
  [  2/129] dbus-broker-0:37-8.fc44.x86_6 100% | 204.6 KiB/s | 178.8 KiB |  00m01s
  [  3/129] systemd-shared-0:259.9-1.fc44 100% |   1.5 MiB/s |   2.0 MiB |  00m01s
  [  4/129] catatonit-0:0.2.1-5.fc44.x86_ 100% | 940.3 KiB/s | 331.9 KiB |  00m00s
  [  5/129] conmon-2:2.2.1-2.fc44.x86_64  100% | 723.0 KiB/s |  56.4 KiB |  00m00s
  [  6/129] podman-5:5.8.7-1.fc44.x86_64  100% |   7.0 MiB/s |  15.4 MiB |  00m02s
  [  7/129] openssl-1:3.5.9-1.fc44.x86_64 100% |   1.8 MiB/s |   1.2 MiB |  00m01s
  [  8/129] systemd-0:259.9-1.fc44.x86_64 100% |   1.3 MiB/s |   4.3 MiB |  00m03s
  [  9/129] selinux-policy-0:44.11-1.fc44 100% |  39.4 KiB/s |  27.0 KiB |  00m01s
  [ 10/129] m4-0:1.4.21-1.fc44.x86_64     100% |   1.0 MiB/s | 347.3 KiB |  00m00s
  [ 11/129] selinux-policy-targeted-0:44. 100% |   5.8 MiB/s |   6.8 MiB |  00m01s
  [ 12/129] make-1:4.4.1-12.fc44.x86_64   100% |   3.3 MiB/s | 588.7 KiB |  00m00s
  [ 13/129] selinux-policy-devel-0:44.11- 100% | 675.4 KiB/s |   1.4 MiB |  00m02s
  [ 14/129] policycoreutils-0:3.11-2.fc44 100% | 244.8 KiB/s | 259.0 KiB |  00m01s
  [ 15/129] libselinux-utils-0:3.11-2.fc4 100% | 118.2 KiB/s | 119.7 KiB |  00m01s
  [ 16/129] checkpolicy-0:3.11-1.fc44.x86 100% |   3.4 MiB/s | 381.9 KiB |  00m00s
  [ 17/129] socat-0:1.8.1.1-1.fc44.x86_64 100% |   3.2 MiB/s | 394.4 KiB |  00m00s
  [ 18/129] diffutils-0:3.12-5.fc44.x86_6 100% |   1.5 MiB/s | 395.3 KiB |  00m00s
  [ 19/129] jq-0:1.8.1-3.fc44.x86_64      100% | 657.0 KiB/s | 215.5 KiB |  00m00s
  [ 20/129] expat-0:2.8.5-1.fc44.x86_64   100% | 689.2 KiB/s | 134.4 KiB |  00m00s
  [ 21/129] oniguruma-0:6.9.10-4.fc44.x86 100% | 472.2 KiB/s | 220.0 KiB |  00m00s
  [ 22/129] libseccomp-0:2.6.1-2.fc44.x86 100% | 441.7 KiB/s |  76.0 KiB |  00m00s
  [ 23/129] cryptsetup-libs-0:2.8.8-1.fc4 100% |   3.4 MiB/s | 629.3 KiB |  00m00s
  [ 24/129] device-mapper-libs-0:1.02.212 100% |   2.4 MiB/s | 186.6 KiB |  00m00s
  [ 25/129] device-mapper-0:1.02.212-2.fc 100% |   1.5 MiB/s | 141.1 KiB |  00m00s
  [ 26/129] libfdisk-0:2.41.5-1.fc44.x86_ 100% | 711.6 KiB/s | 168.6 KiB |  00m00s
  [ 27/129] util-linux-0:2.41.5-1.fc44.x8 100% |   5.6 MiB/s |   1.2 MiB |  00m00s
  [ 28/129] policycoreutils-devel-0:3.11- 100% | 826.6 KiB/s | 148.0 KiB |  00m00s
  [ 29/129] policycoreutils-python-utils- 100% | 400.1 KiB/s |  50.4 KiB |  00m00s
  [ 30/129] python3-policycoreutils-0:3.1 100% |  13.9 MiB/s |   2.2 MiB |  00m00s
  [ 31/129] python3-libselinux-0:3.11-2.f 100% |   1.3 MiB/s | 212.0 KiB |  00m00s
  [ 32/129] python3-distro-0:1.9.0-11.fc4 100% | 638.0 KiB/s |  47.2 KiB |  00m00s
  [ 33/129] python3-libsemanage-0:3.11-1. 100% | 207.4 KiB/s |  84.4 KiB |  00m00s
  [ 34/129] python3-0:3.14.8-1.fc44.x86_6 100% |  83.3 KiB/s |  29.4 KiB |  00m00s
  [ 35/129] mpdecimal-0:4.0.1-3.fc44.x86_ 100% |   1.2 MiB/s |  99.1 KiB |  00m00s
  [ 36/129] python3-audit-0:4.2.1-1.fc44. 100% |  57.0 KiB/s |  73.4 KiB |  00m01s
  [ 37/129] python3-libs-0:3.14.8-1.fc44. 100% |   6.3 MiB/s |  10.2 MiB |  00m02s
  [ 38/129] python3-setools-0:4.6.0-6.fc4 100% | 579.2 KiB/s | 730.4 KiB |  00m01s
  [ 39/129] python-pip-wheel-0:26.0.1-3.f 100% |   9.3 MiB/s |   1.1 MiB |  00m00s
  [ 40/129] python3-libdnf5-0:5.4.6.0-1.f 100% |  14.5 MiB/s |   1.9 MiB |  00m00s
  [ 41/129] containers-common-extra-5:0.6 100% |  74.0 KiB/s |   9.5 KiB |  00m00s
  [ 42/129] containers-common-5:0.67.2-1. 100% | 220.5 KiB/s | 102.1 KiB |  00m00s
  [ 43/129] gpgme-0:2.0.1-5.fc44.x86_64   100% | 571.2 KiB/s | 231.9 KiB |  00m00s
  [ 44/129] netavark-2:1.17.2-1.fc44.x86_ 100% |   5.1 MiB/s |   3.0 MiB |  00m01s
  [ 45/129] podman-sequoia-0:0.3.2-2.fc44 100% |  10.2 MiB/s |   2.4 MiB |  00m00s
  [ 46/129] shadow-utils-subid-2:4.19.0-7 100% | 133.0 KiB/s |  30.7 KiB |  00m00s
  [ 47/129] crun-0:1.28-1.fc44.x86_64     100% | 515.6 KiB/s | 269.1 KiB |  00m01s
  [ 48/129] passt-0:0^20261002.gcba3570-1 100% | 694.4 KiB/s | 331.2 KiB |  00m00s
  [ 49/129] passt-selinux-0:0^20261002.gc 100% |  64.6 KiB/s |  30.8 KiB |  00m00s
  [ 50/129] nftables-1:1.1.6-2.fc44.x86_6 100% |   4.9 MiB/s | 450.5 KiB |  00m00s
  [ 51/129] jansson-0:2.14-4.fc44.x86_64  100% | 611.9 KiB/s |  47.1 KiB |  00m00s
  [ 52/129] libmnl-0:1.0.5-9.fc44.x86_64  100% | 379.2 KiB/s |  28.1 KiB |  00m00s
  [ 53/129] libnftnl-0:1.3.1-2.fc44.x86_6 100% |   1.1 MiB/s |  90.1 KiB |  00m00s
  [ 54/129] nftables-services-1:1.1.6-2.f 100% | 273.9 KiB/s |  21.6 KiB |  00m00s
  [ 55/129] iptables-libs-0:1.8.11-13.fc4 100% | 887.4 KiB/s | 405.5 KiB |  00m00s
  [ 56/129] libnetfilter_conntrack-0:1.1. 100% | 825.3 KiB/s |  61.9 KiB |  00m00s
  [ 57/129] libnfnetlink-0:1.0.1-32.fc44. 100% | 398.5 KiB/s |  29.9 KiB |  00m00s
  [ 58/129] aardvark-dns-2:1.17.1-1.fc44. 100% | 983.1 KiB/s | 859.3 KiB |  00m01s
  [ 59/129] liblastlog2-0:2.41.5-1.fc44.x 100% |  61.7 KiB/s |  24.2 KiB |  00m00s
  [ 60/129] container-selinux-4:2.251.0-1 100% | 173.8 KiB/s |  58.4 KiB |  00m00s
  [ 61/129] rpm-plugin-selinux-0:6.0.1-2. 100% | 245.6 KiB/s |  19.2 KiB |  00m00s
  [ 62/129] libxkbcommon-0:1.13.1-2.fc44. 100% |   2.3 MiB/s | 185.8 KiB |  00m00s
  [ 63/129] kmod-libs-0:34.2-4.fc44.x86_6 100% | 891.1 KiB/s |  70.4 KiB |  00m00s
  [ 64/129] xkeyboard-config-0:2.47-1.fc4 100% |   6.3 MiB/s |   1.0 MiB |  00m00s
  [ 65/129] qrencode-libs-0:4.1.1-12.fc44 100% | 821.7 KiB/s |  64.1 KiB |  00m00s
  [ 66/129] dbus-1:1.16.2-1.fc44.x86_64   100% |  98.3 KiB/s |   7.5 KiB |  00m00s
  [ 67/129] libedit-0:3.1-59.20260512cvs. 100% | 251.0 KiB/s | 110.4 KiB |  00m00s
  [ 68/129] libbpf-2:1.6.3-2.fc44.x86_64  100% | 714.3 KiB/s | 199.3 KiB |  00m00s
  [ 69/129] systemd-networkd-0:259.9-1.fc 100% |   3.2 MiB/s | 797.7 KiB |  00m00s
  [ 70/129] systemd-resolved-0:259.9-1.fc 100% |   1.4 MiB/s | 286.4 KiB |  00m00s
  [ 71/129] systemd-pam-0:259.9-1.fc44.x8 100% |   2.0 MiB/s | 440.4 KiB |  00m00s
  [ 72/129] python-unversioned-command-0: 100% |  19.4 KiB/s |  11.6 KiB |  00m01s
  [ 73/129] libdnf5-plugin-systemd-inhibi 100% |  61.7 KiB/s |  36.1 KiB |  00m01s
  [ 74/129] libdnf5-plugin-expired-pgp-ke 100% | 113.5 KiB/s |  65.4 KiB |  00m01s
  [ 75/129] qemu-user-static-2:10.2.2-1.f 100% | 358.9 KiB/s |  28.0 KiB |  00m00s
  [ 76/129] qemu-user-static-arm-2:10.2.2 100% |   7.3 MiB/s |   2.3 MiB |  00m00s
  [ 77/129] qemu-user-static-hexagon-2:10 100% |  16.0 MiB/s |   1.8 MiB |  00m00s
  [ 78/129] qemu-user-static-aarch64-2:10 100% |   5.3 MiB/s |   2.9 MiB |  00m01s
  [ 79/129] qemu-user-static-hppa-2:10.2. 100% |  14.1 MiB/s |   1.5 MiB |  00m00s
  [ 80/129] qemu-user-static-alpha-2:10.2 100% |   2.3 MiB/s |   1.5 MiB |  00m01s
  [ 81/129] qemu-user-static-loongarch64- 100% |  12.9 MiB/s |   1.6 MiB |  00m00s
  [ 82/129] qemu-user-static-m68k-2:10.2. 100% |  14.4 MiB/s |   1.5 MiB |  00m00s
  [ 83/129] qemu-user-static-mips-2:10.2. 100% |  19.2 MiB/s |   4.1 MiB |  00m00s
  [ 84/129] qemu-user-static-microblaze-2 100% |   7.3 MiB/s |   1.8 MiB |  00m00s
  [ 85/129] qemu-user-static-or1k-2:10.2. 100% |   8.2 MiB/s |   1.5 MiB |  00m00s
  [ 86/129] qemu-user-static-ppc-2:10.2.2 100% |  21.5 MiB/s |   2.7 MiB |  00m00s
  [ 87/129] qemu-user-static-s390x-2:10.2 100% |  11.2 MiB/s |   1.6 MiB |  00m00s
  [ 88/129] qemu-user-static-riscv-2:10.2 100% |  12.9 MiB/s |   2.3 MiB |  00m00s
  [ 89/129] qemu-user-static-sh4-2:10.2.2 100% |   8.4 MiB/s |   1.8 MiB |  00m00s
  [ 90/129] qemu-user-static-x86-2:10.2.2 100% |  12.7 MiB/s |   2.1 MiB |  00m00s
  [ 91/129] qemu-user-static-sparc-2:10.2 100% |  11.7 MiB/s |   2.3 MiB |  00m00s
  [ 92/129] composefs-0:1.0.8-5.fc44.x86_ 100% | 763.3 KiB/s |  63.4 KiB |  00m00s
  [ 93/129] composefs-libs-0:1.0.8-5.fc44 100% | 723.8 KiB/s |  56.5 KiB |  00m00s
  [ 94/129] qemu-user-static-xtensa-2:10. 100% |  18.3 MiB/s |   2.4 MiB |  00m00s
  [ 95/129] kmod-0:34.2-4.fc44.x86_64     100% |   1.2 MiB/s | 136.1 KiB |  00m00s
  [ 96/129] fuse-overlayfs-0:1.17-1.fc44. 100% |  85.4 KiB/s |  69.2 KiB |  00m01s
  [ 97/129] criu-libs-0:4.2.1-1.fc44.x86_ 100% |  44.3 KiB/s |  34.2 KiB |  00m01s
  [ 98/129] protobuf-c-0:1.5.2-2.fc44.x86 100% | 461.6 KiB/s |  33.7 KiB |  00m00s
  [ 99/129] libbsd-0:0.12.2-7.fc44.x86_64 100% |   1.6 MiB/s | 124.3 KiB |  00m00s
  [100/129] libnet-0:1.3-7.fc44.x86_64    100% | 781.0 KiB/s |  64.0 KiB |  00m00s
  [101/129] libnl3-0:3.12.0-3.fc44.x86_64 100% |   4.3 MiB/s | 377.3 KiB |  00m00s
  [102/129] pkgconf-pkg-config-0:2.5.1-1. 100% | 121.4 KiB/s |   9.5 KiB |  00m00s
  [103/129] criu-0:4.2.1-1.fc44.x86_64    100% | 642.7 KiB/s | 621.5 KiB |  00m01s
  [104/129] pkgconf-0:2.5.1-1.fc44.x86_64 100% | 667.0 KiB/s |  48.7 KiB |  00m00s
  [105/129] pkgconf-m4-0:2.5.1-1.fc44.noa 100% | 191.0 KiB/s |  13.8 KiB |  00m00s
  [106/129] libpkgconf-0:2.5.1-1.fc44.x86 100% | 592.7 KiB/s |  42.7 KiB |  00m00s
  [107/129] libmd-0:1.3.0-1.fc44.x86_64   100% | 134.9 KiB/s |  56.8 KiB |  00m00s
  [108/129] fuse3-0:3.18.3-1.fc44.x86_64  100% | 257.9 KiB/s |  63.2 KiB |  00m00s
  [109/129] fuse3-libs-0:3.18.3-1.fc44.x8 100% | 511.2 KiB/s | 102.2 KiB |  00m00s
  [110/129] fuse-common-0:3.18.3-1.fc44.x 100% |  47.7 KiB/s |   8.1 KiB |  00m00s
  [111/129] systemd-udev-0:259.9-1.fc44.x 100% |   7.2 MiB/s |   2.7 MiB |  00m00s
  [112/129] kbd-0:2.9.0-4.fc44.x86_64     100% |   1.0 MiB/s | 389.0 KiB |  00m00s
  [113/129] kbd-legacy-0:2.9.0-4.fc44.noa 100% |   2.1 MiB/s | 581.3 KiB |  00m00s
  [114/129] kbd-misc-0:2.9.0-4.fc44.noarc 100% |  13.3 MiB/s |   1.7 MiB |  00m00s
  [115/129] systemd-libs-0:259.9-1.fc44.x 100% |   6.5 MiB/s | 868.8 KiB |  00m00s
  [116/129] openssl-libs-1:3.5.9-1.fc44.x 100% |  11.6 MiB/s |   2.8 MiB |  00m00s
  [117/129] libsepol-0:3.11-1.fc44.x86_64 100% |   1.8 MiB/s | 365.3 KiB |  00m00s
  [118/129] libselinux-0:3.11-2.fc44.x86_ 100% | 534.7 KiB/s | 104.3 KiB |  00m00s
  [119/129] util-linux-core-0:2.41.5-1.fc 100% |   3.3 MiB/s | 558.1 KiB |  00m00s
  [120/129] libblkid-0:2.41.5-1.fc44.x86_ 100% | 754.9 KiB/s | 129.8 KiB |  00m00s
  [121/129] libmount-0:2.41.5-1.fc44.x86_ 100% | 991.0 KiB/s | 172.4 KiB |  00m00s
  [122/129] libsmartcols-0:2.41.5-1.fc44. 100% | 143.5 KiB/s |  87.4 KiB |  00m01s
  [123/129] libuuid-0:2.41.5-1.fc44.x86_6 100% |  42.1 KiB/s |  27.1 KiB |  00m01s
  [124/129] libsemanage-0:3.11-1.fc44.x86 100% | 198.3 KiB/s | 127.3 KiB |  00m01s
  [125/129] audit-libs-0:4.2.1-1.fc44.x86 100% | 119.7 KiB/s | 143.6 KiB |  00m01s
  [126/129] libdnf5-0:5.4.6.0-1.fc44.x86_ 100% |   1.1 MiB/s |   1.4 MiB |  00m01s
  [127/129] libdnf5-cli-0:5.4.6.0-1.fc44. 100% | 281.4 KiB/s | 374.3 KiB |  00m01s
  [128/129] dnf5-plugins-0:5.4.6.0-1.fc44 100% |   1.9 MiB/s | 539.2 KiB |  00m00s
  [129/129] dnf5-0:5.4.6.0-1.fc44.x86_64  100% |   3.2 MiB/s |   1.0 MiB |  00m00s
  --------------------------------------------------------------------------------
  [129/129] Total                         100% |   6.8 MiB/s | 116.9 MiB |  00m17s
  Running transaction
  [  1/146] Verify package files          100% | 490.0   B/s | 129.0   B |  00m00s
  [  2/146] Prepare transaction           100% |   2.2 KiB/s | 144.0   B |  00m00s
  [  3/146] Upgrading openssl-libs-1:3.5. 100% | 249.0 MiB/s |   9.2 MiB |  00m00s
  [  4/146] Upgrading libuuid-0:2.41.5-1. 100% |  12.5 MiB/s |  38.3 KiB |  00m00s
  [  5/146] Upgrading systemd-libs-0:259. 100% | 175.0 MiB/s |   2.5 MiB |  00m00s
  [  6/146] Upgrading libblkid-0:2.41.5-1 100% |  67.2 MiB/s | 275.3 KiB |  00m00s
  [  7/146] Upgrading libdnf5-0:5.4.6.0-1 100% | 298.7 MiB/s |   4.8 MiB |  00m00s
  [  8/146] Upgrading audit-libs-0:4.2.1- 100% |  64.0 MiB/s | 393.1 KiB |  00m00s
  [  9/146] Upgrading libsepol-0:3.11-1.f 100% | 140.5 MiB/s | 863.0 KiB |  00m00s
  [ 10/146] Upgrading libselinux-0:3.11-2 100% |  50.4 MiB/s | 206.5 KiB |  00m00s
  [ 11/146] Installing systemd-shared-0:2 100% | 340.6 MiB/s |   5.5 MiB |  00m00s
  [ 12/146] Installing libseccomp-0:2.6.1 100% |  72.9 MiB/s | 224.0 KiB |  00m00s
  [ 13/146] Installing libselinux-utils-0 100% |  16.5 MiB/s | 320.2 KiB |  00m00s
  [ 14/146] Upgrading libmount-0:2.41.5-1 100% |  96.1 MiB/s | 393.7 KiB |  00m00s
  [ 15/146] Upgrading libsemanage-0:3.11- 100% |  77.7 MiB/s | 318.2 KiB |  00m00s
  [ 16/146] Installing libfdisk-0:2.41.5- 100% |  95.1 MiB/s | 389.4 KiB |  00m00s
  [ 17/146] Upgrading libsmartcols-0:2.41 100% |  46.3 MiB/s | 189.5 KiB |  00m00s
  [ 18/146] Upgrading util-linux-core-0:2 100% |  49.3 MiB/s |   1.5 MiB |  00m00s
  [ 19/146] Installing libmnl-0:1.0.5-9.f 100% |  17.0 MiB/s |  52.3 KiB |  00m00s
  [ 20/146] Upgrading libdnf5-cli-0:5.4.6 100% | 180.2 MiB/s |   1.1 MiB |  00m00s
  [ 21/146] Installing fuse3-libs-0:3.18. 100% |  97.3 MiB/s | 298.9 KiB |  00m00s
  [ 22/146] Installing protobuf-c-0:1.5.2 100% |  18.0 MiB/s |  55.2 KiB |  00m00s
  [ 23/146] Installing qemu-user-static-x 100% | 201.5 MiB/s |   9.7 MiB |  00m00s
  [ 24/146] Installing qemu-user-static-a 100% | 222.6 MiB/s |  10.9 MiB |  00m00s
  [ 25/146] Installing qemu-user-static-a 100% | 272.4 MiB/s |  15.3 MiB |  00m00s
  [ 26/146] Installing expat-0:2.8.5-1.fc 100% |  25.9 MiB/s | 344.3 KiB |  00m00s
  [ 27/146] Installing checkpolicy-0:3.11 100% | 103.5 MiB/s |   1.7 MiB |  00m00s
  [ 28/146] Installing make-1:4.4.1-12.fc 100% | 128.6 MiB/s |   1.8 MiB |  00m00s
  [ 29/146] Upgrading dnf5-0:5.4.6.0-1.fc 100% | 108.1 MiB/s |   3.5 MiB |  00m00s
  [ 30/146] Installing libnftnl-0:1.3.1-2 100% |  77.6 MiB/s | 238.3 KiB |  00m00s
  [ 31/146] Installing shadow-utils-subid 100% |   3.9 MiB/s |  51.4 KiB |  00m00s
  [ 32/146] Installing conmon-2:2.2.1-2.f 100% |  15.0 MiB/s | 184.6 KiB |  00m00s
  [ 33/146] Installing crun-0:1.28-1.fc44 100% |  45.6 MiB/s | 607.0 KiB |  00m00s
  [ 34/146] Installing podman-sequoia-0:0 100% | 317.0 MiB/s |   7.0 MiB |  00m00s
  [ 35/146] Installing kmod-libs-0:34.2-4 100% |  34.2 MiB/s | 140.1 KiB |  00m00s
  [ 36/146] Installing composefs-libs-0:1 100% |  35.1 MiB/s | 143.9 KiB |  00m00s
  [ 37/146] Installing kbd-misc-0:2.9.0-4 100% |  61.7 MiB/s |   2.5 MiB |  00m00s
  [ 38/146] Installing kbd-legacy-0:2.9.0 100% |  23.8 MiB/s | 610.1 KiB |  00m00s
  [ 39/146] Installing kbd-0:2.9.0-4.fc44 100% |  70.0 MiB/s |   1.5 MiB |  00m00s
  [ 40/146] Installing fuse-common-0:3.18 100% | 142.6 KiB/s | 292.0   B |  00m00s
  [ 41/146] Installing fuse3-0:3.18.3-1.f 100% |  11.5 MiB/s | 141.4 KiB |  00m00s
  [ 42/146] Installing libpkgconf-0:2.5.1 100% |  29.7 MiB/s |  91.3 KiB |  00m00s
  [ 43/146] Installing pkgconf-0:2.5.1-1. 100% |   6.6 MiB/s |  95.2 KiB |  00m00s
  [ 44/146] Installing pkgconf-m4-0:2.5.1 100% |   4.8 MiB/s |  14.7 KiB |  00m00s
  [ 45/146] Installing pkgconf-pkg-config 100% | 161.2 KiB/s |   1.8 KiB |  00m00s
  [ 46/146] Installing kmod-0:34.2-4.fc44 100% |  17.9 MiB/s | 256.9 KiB |  00m00s
  [ 47/146] Installing fuse-overlayfs-0:1 100% |   5.2 MiB/s | 137.5 KiB |  00m00s
  [ 48/146] Installing libmd-0:1.3.0-1.fc 100% |  43.4 MiB/s | 133.2 KiB |  00m00s
  [ 49/146] Installing libbsd-0:0.12.2-7. 100% | 138.2 MiB/s | 424.6 KiB |  00m00s
  [ 50/146] Installing libnl3-0:3.12.0-3. 100% | 133.3 MiB/s |   1.1 MiB |  00m00s
  [ 51/146] Installing libnet-0:1.3-7.fc4 100% |  47.5 MiB/s | 145.9 KiB |  00m00s
  [ 52/146] Installing qemu-user-static-x 100% | 257.8 MiB/s |  14.7 MiB |  00m00s
  [ 53/146] Installing qemu-user-static-s 100% | 255.8 MiB/s |  13.0 MiB |  00m00s
  [ 54/146] Installing qemu-user-static-s 100% | 189.9 MiB/s |   8.4 MiB |  00m00s
  [ 55/146] Installing qemu-user-static-s 100% | 124.4 MiB/s |   4.6 MiB |  00m00s
  [ 56/146] Installing qemu-user-static-r 100% | 222.6 MiB/s |  11.1 MiB |  00m00s
  [ 57/146] Installing qemu-user-static-p 100% | 274.1 MiB/s |  15.3 MiB |  00m00s
  [ 58/146] Installing qemu-user-static-o 100% | 125.1 MiB/s |   4.1 MiB |  00m00s
  [ 59/146] Installing qemu-user-static-m 100% | 369.0 MiB/s |  31.4 MiB |  00m00s
  [ 60/146] Installing qemu-user-static-m 100% | 194.0 MiB/s |   8.3 MiB |  00m00s
  [ 61/146] Installing qemu-user-static-m 100% | 119.0 MiB/s |   4.4 MiB |  00m00s
  [ 62/146] Installing qemu-user-static-l 100% | 130.0 MiB/s |   4.9 MiB |  00m00s
  [ 63/146] Installing qemu-user-static-h 100% | 121.4 MiB/s |   4.2 MiB |  00m00s
  [ 64/146] Installing qemu-user-static-h 100% | 153.9 MiB/s |   6.0 MiB |  00m00s
  [ 65/146] Installing qemu-user-static-a 100% | 119.8 MiB/s |   4.2 MiB |  00m00s
  [ 66/146] Installing libbpf-2:1.6.3-2.f 100% |  72.2 MiB/s | 443.5 KiB |  00m00s
  [ 67/146] Installing xkeyboard-config-0 100% | 184.8 MiB/s |   6.5 MiB |  00m00s
  [ 68/146] Installing libedit-0:3.1-59.2 100% |  81.4 MiB/s | 250.0 KiB |  00m00s
  [ 69/146] Installing liblastlog2-0:2.41 100% |   2.7 MiB/s |  43.7 KiB |  00m00s
  [ 70/146] Installing util-linux-0:2.41. 100% |  28.2 MiB/s |   3.6 MiB |  00m00s
  >>> Running sysusers scriptlet: systemd-0:259.9-1.fc44.x86_64
  >>> Finished sysusers scriptlet: systemd-0:259.9-1.fc44.x86_64
  >>> Scriptlet output:
  >>> Creating group 'empower' with GID 999.
  >>> 
  >>> Running sysusers scriptlet: systemd-0:259.9-1.fc44.x86_64
  >>> Finished sysusers scriptlet: systemd-0:259.9-1.fc44.x86_64
  >>> Scriptlet output:
  >>> Creating group 'systemd-journal' with GID 190.
  >>> 
  >>> Running sysusers scriptlet: systemd-0:259.9-1.fc44.x86_64
  >>> Finished sysusers scriptlet: systemd-0:259.9-1.fc44.x86_64
  >>> Scriptlet output:
  >>> Creating group 'systemd-oom' with GID 998.
  >>> Creating user 'systemd-oom' (systemd Userspace OOM Killer) with UID 998 and GID 998.
  >>> 
  [ 71/146] Installing systemd-0:259.9-1. 100% |  53.9 MiB/s |  13.1 MiB |  00m00s
  [ 72/146] Installing device-mapper-0:1. 100% |  24.4 MiB/s | 350.3 KiB |  00m00s
  [ 73/146] Installing device-mapper-libs 100% |  84.2 MiB/s | 431.3 KiB |  00m00s
  [ 74/146] Installing cryptsetup-libs-0: 100% | 496.9 MiB/s |   3.0 MiB |  00m00s
  [ 75/146] Installing libnfnetlink-0:1.0 100% |  16.8 MiB/s |  51.5 KiB |  00m00s
  [ 76/146] Installing libnetfilter_connt 100% |  47.2 MiB/s | 145.0 KiB |  00m00s
  [ 77/146] Installing iptables-libs-0:1. 100% |  65.9 MiB/s |   1.5 MiB |  00m00s
  [ 78/146] Installing jansson-0:2.14-4.f 100% |  44.1 MiB/s |  90.3 KiB |  00m00s
  [ 79/146] Installing nftables-1:1.1.6-2 100% |  76.3 MiB/s |   1.1 MiB |  00m00s
  [ 80/146] Installing nftables-services- 100% |   1.7 MiB/s |  33.3 KiB |  00m00s
  [ 81/146] Installing criu-0:4.2.1-1.fc4 100% |  50.3 MiB/s |   1.7 MiB |  00m00s
  [ 82/146] Installing aardvark-dns-2:1.1 100% | 226.6 MiB/s |   2.3 MiB |  00m00s
  [ 83/146] Installing netavark-2:1.17.2- 100% | 340.9 MiB/s |   8.9 MiB |  00m00s
  [ 84/146] Installing gpgme-0:2.0.1-5.fc 100% |  37.9 MiB/s | 620.8 KiB |  00m00s
  [ 85/146] Installing python-pip-wheel-0 100% | 244.7 MiB/s |   1.2 MiB |  00m00s
  [ 86/146] Installing mpdecimal-0:4.0.1- 100% |  30.5 MiB/s | 218.6 KiB |  00m00s
  [ 87/146] Installing python3-libs-0:3.1 100% | 171.1 MiB/s |  44.5 MiB |  00m00s
  [ 88/146] Installing python3-0:3.14.8-1 100% |   2.5 MiB/s |  30.4 KiB |  00m00s
  [ 89/146] Installing python3-libselinux 100% |  88.3 MiB/s | 632.8 KiB |  00m00s
  [ 90/146] Installing python3-libsemanag 100% |  97.7 MiB/s | 400.3 KiB |  00m00s
  [ 91/146] Installing python3-distro-0:1 100% |  14.0 MiB/s | 214.9 KiB |  00m00s
  [ 92/146] Installing python3-audit-0:4. 100% |  58.1 MiB/s | 297.3 KiB |  00m00s
  [ 93/146] Installing python3-setools-0: 100% | 130.8 MiB/s |   2.9 MiB |  00m00s
  [ 94/146] Installing python3-libdnf5-0: 100% | 308.8 MiB/s |  10.5 MiB |  00m00s
  [ 95/146] Installing oniguruma-0:6.9.10 100% | 151.0 MiB/s | 773.1 KiB |  00m00s
  [ 96/146] Installing diffutils-0:3.12-5 100% | 112.3 MiB/s |   1.6 MiB |  00m00s
  [ 97/146] Installing policycoreutils-0: 100% |  26.2 MiB/s | 913.0 KiB |  00m00s
  >>> Running %post scriptlet: policycoreutils-0:3.11-2.fc44.x86_64
  >>> Finished %post scriptlet: policycoreutils-0:3.11-2.fc44.x86_64
  >>> Scriptlet output:
  >>> Created symlink '/etc/systemd/system/sysinit.target.wants/selinux-autorelabel-mark.service' ƒ+' '/usr/lib/systemd/system/selinux-autorelabel-mark.service'.
  >>> 
  [ 98/146] Installing selinux-policy-0:4 100% | 704.8 KiB/s |  34.5 KiB |  00m00s
  [ 99/146] Installing selinux-policy-tar 100% |  45.4 MiB/s |  14.9 MiB |  00m00s
  [100/146] Installing container-selinux- 100% |   7.9 KiB/s |  79.3 KiB |  00m10s
  [101/146] Installing containers-common- 100% |   5.5 MiB/s | 141.2 KiB |  00m00s
  [102/146] Installing passt-selinux-0:0^ 100% |  42.7 KiB/s | 379.0 KiB |  00m09s
  [103/146] Installing passt-0:0^20261002 100% |  81.0 MiB/s |   1.6 MiB |  00m00s
  [104/146] Installing containers-common- 100% |  60.5 KiB/s | 124.0   B |  00m00s
  [105/146] Installing python3-policycore 100% | 267.8 MiB/s |   5.9 MiB |  00m00s
  [106/146] Installing policycoreutils-py 100% |   8.0 MiB/s |  98.2 KiB |  00m00s
  [107/146] Installing m4-0:1.4.21-1.fc44 100% |  66.7 MiB/s | 887.6 KiB |  00m00s
  [108/146] Installing policycoreutils-de 100% |  21.0 MiB/s | 344.3 KiB |  00m00s
  [109/146] Installing selinux-policy-dev 100% | 204.4 MiB/s |  23.3 MiB |  00m00s
  [110/146] Installing catatonit-0:0.2.1- 100% |  24.1 MiB/s | 790.0 KiB |  00m00s
  >>> Running sysusers scriptlet: dbus-common-1:1.16.2-1.fc44.noarch
  >>> Finished sysusers scriptlet: dbus-common-1:1.16.2-1.fc44.noarch
  >>> Scriptlet output:
  >>> Creating group 'dbus' with GID 81.
  >>> Creating user 'dbus' (System Message Bus) with UID 81 and GID 81.
  >>> 
  [111/146] Installing dbus-common-1:1.16 100% | 330.5 KiB/s |  13.6 KiB |  00m00s
  >>> Running %post scriptlet: dbus-common-1:1.16.2-1.fc44.noarch
  >>> Finished %post scriptlet: dbus-common-1:1.16.2-1.fc44.noarch
  >>> Scriptlet output:
  >>> Created symlink '/etc/systemd/system/sockets.target.wants/dbus.socket' ƒ+' '/usr/lib/systemd/system/dbus.socket'.
  >>> Created symlink '/etc/systemd/user/sockets.target.wants/dbus.socket' ƒ+' '/usr/lib/systemd/user/dbus.socket'.
  >>> 
  [112/146] Installing dbus-broker-0:37-8 100% |  10.8 MiB/s | 397.5 KiB |  00m00s
  >>> Running %post scriptlet: dbus-broker-0:37-8.fc44.x86_64
  >>> Finished %post scriptlet: dbus-broker-0:37-8.fc44.x86_64
  >>> Scriptlet output:
  >>> Created symlink '/etc/systemd/system/dbus.service' ƒ+' '/usr/lib/systemd/system/dbus-broker.service'.
  >>> Created symlink '/etc/systemd/user/dbus.service' ƒ+' '/usr/lib/systemd/user/dbus-broker.service'.
  >>> 
  [113/146] Installing dbus-1:1.16.2-1.fc 100% |  60.5 KiB/s | 124.0   B |  00m00s
  [114/146] Installing podman-5:5.8.7-1.f 100% | 503.4 MiB/s |  49.3 MiB |  00m00s
  [115/146] Installing jq-0:1.8.1-3.fc44. 100% |  35.1 MiB/s | 467.8 KiB |  00m00s
  [116/146] Installing python-unversioned 100% |  41.4 KiB/s | 424.0   B |  00m00s
  [117/146] Installing criu-libs-0:4.2.1- 100% |   1.6 MiB/s |  90.3 KiB |  00m00s
  >>> Running sysusers scriptlet: systemd-udev-0:259.9-1.fc44.x86_64
  >>> Finished sysusers scriptlet: systemd-udev-0:259.9-1.fc44.x86_64
  >>> Scriptlet output:
  >>> Creating group 'systemd-coredump' with GID 997.
  >>> Creating user 'systemd-coredump' (systemd Core Dumper) with UID 997 and GID 997.
  >>> 
  >>> Running sysusers scriptlet: systemd-udev-0:259.9-1.fc44.x86_64
  >>> Finished sysusers scriptlet: systemd-udev-0:259.9-1.fc44.x86_64
  >>> Scriptlet output:
  >>> Creating group 'systemd-timesync' with GID 996.
  >>> Creating user 'systemd-timesync' (systemd Time Synchronization) with UID 996 and GID 996.
  >>> 
  [118/146] Installing systemd-udev-0:259 100% |  32.1 MiB/s |  13.2 MiB |  00m00s
  >>> Running %post scriptlet: systemd-udev-0:259.9-1.fc44.x86_64
  >>> Finished %post scriptlet: systemd-udev-0:259.9-1.fc44.x86_64
  >>> Scriptlet output:
  >>> Failed to preset unit: Unit systemd-tmpfiles-clear.service does not exist
  >>> Created symlink '/etc/systemd/system/multi-user.target.wants/remote-cryptsetup.target' ƒ+' '/usr/lib/systemd/system/remote-cryptsetup.target'.
  >>> Created symlink '/etc/systemd/system/multi-user.target.wants/remote-veritysetup.target' ƒ+' '/usr/lib/systemd/system/remote-veritysetup.target'.
  >>> Created symlink '/etc/systemd/system/systemd-homed.service.wants/systemd-homed-activate.service' ƒ+' '/usr/lib/systemd/system/systemd-homed-activate.service'.
  >>> Created symlink '/etc/systemd/system/dbus-org.freedesktop.home1.service' ƒ+' '/usr/lib/systemd/system/systemd-homed.service'.
  >>> Created symlink '/etc/systemd/system/multi-user.target.wants/systemd-homed.service' ƒ+' '/usr/lib/systemd/system/systemd-homed.service'.
  >>> Created symlink '/etc/systemd/system/sysinit.target.wants/systemd-network-generator.service' ƒ+' '/usr/lib/systemd/system/systemd-network-generator.service'.
  >>> Created symlink '/etc/systemd/system/dbus-org.freedesktop.oom1.service' ƒ+' '/usr/lib/systemd/system/systemd-oomd.service'.
  >>> Created symlink '/etc/systemd/system/multi-user.target.wants/systemd-oomd.service' ƒ+' '/usr/lib/systemd/system/systemd-oomd.service'.
  >>> Created symlink '/etc/systemd/system/sockets.target.wants/systemd-oomd.socket' ƒ+' '/usr/lib/systemd/system/systemd-oomd.socket'.
  >>> Created symlink '/etc/systemd/system/sysinit.target.wants/systemd-pstore.service' ƒ+' '/usr/lib/systemd/system/systemd-pstore.service'.
  >>> 
  >>> Running sysusers scriptlet: systemd-networkd-0:259.9-1.fc44.x86_64
  >>> Finished sysusers scriptlet: systemd-networkd-0:259.9-1.fc44.x86_64
  >>> Scriptlet output:
  >>> Creating group 'systemd-network' with GID 192.
  >>> Creating user 'systemd-network' (systemd Network Management) with UID 192 and GID 192.
  >>> 
  [119/146] Installing systemd-networkd-0 100% |  33.5 MiB/s |   2.3 MiB |  00m00s
  >>> Running sysusers scriptlet: systemd-resolved-0:259.9-1.fc44.x86_64
  >>> Finished sysusers scriptlet: systemd-resolved-0:259.9-1.fc44.x86_64
  >>> Scriptlet output:
  >>> Creating group 'systemd-resolve' with GID 193.
  >>> Creating user 'systemd-resolve' (systemd Resolver) with UID 193 and GID 193.
  >>> 
  [120/146] Installing systemd-resolved-0 100% |  17.9 MiB/s | 659.7 KiB |  00m00s
  >>> Running %post scriptlet: systemd-resolved-0:259.9-1.fc44.x86_64
  >>> Finished %post scriptlet: systemd-resolved-0:259.9-1.fc44.x86_64
  >>> Scriptlet output:
  >>> Created symlink '/etc/systemd/system/dbus-org.freedesktop.resolve1.service' ƒ+' '/usr/lib/systemd/system/systemd-resolved.service'.
  >>> Created symlink '/etc/systemd/system/sysinit.target.wants/systemd-resolved.service' ƒ+' '/usr/lib/systemd/system/systemd-resolved.service'.
  >>> Created symlink '/etc/systemd/system/sockets.target.wants/systemd-resolved-varlink.socket' ƒ+' '/usr/lib/systemd/system/systemd-resolved-varlink.socket'.
  >>> Created symlink '/etc/systemd/system/sockets.target.wants/systemd-resolved-monitor.socket' ƒ+' '/usr/lib/systemd/system/systemd-resolved-monitor.socket'.
  >>> 
  [121/146] Installing systemd-pam-0:259. 100% | 244.4 MiB/s |   1.2 MiB |  00m00s
  [122/146] Installing qemu-user-static-2 100% |  22.0 MiB/s |  45.1 KiB |  00m00s
  [123/146] Installing libxkbcommon-0:1.1 100% | 105.9 MiB/s | 433.9 KiB |  00m00s
  [124/146] Installing composefs-0:1.0.8- 100% |  11.9 MiB/s | 171.1 KiB |  00m00s
  [125/146] Upgrading dnf5-plugins-0:5.4. 100% | 145.9 MiB/s |   1.6 MiB |  00m00s
  [126/146] Installing rpm-plugin-selinux 100% |   6.3 MiB/s |  12.9 KiB |  00m00s
  [127/146] Installing libdnf5-plugin-sys 100% |  14.1 MiB/s |  28.8 KiB |  00m00s
  [128/146] Installing libdnf5-plugin-exp 100% |  31.2 MiB/s |  95.9 KiB |  00m00s
  [129/146] Installing openssl-1:3.5.9-1. 100% |  65.7 MiB/s |   1.9 MiB |  00m00s
  [130/146] Installing socat-0:1.8.1.1-1. 100% | 119.1 MiB/s |   1.4 MiB |  00m00s
  [131/146] Installing qrencode-libs-0:4. 100% |  27.1 MiB/s | 166.5 KiB |  00m00s
  [132/146] Removing util-linux-core-0:2. 100% |  16.2 KiB/s | 149.0   B |  00m00s
  [133/146] Removing libsemanage-0:3.10-1 100% |  11.7 KiB/s |  12.0   B |  00m00s
  [134/146] Removing libmount-0:2.41.3-12 100% |   6.8 KiB/s |   7.0   B |  00m00s
  [135/146] Removing dnf5-plugins-0:5.4.1 100% |   8.6 KiB/s | 265.0   B |  00m00s
  [136/146] Removing dnf5-0:5.4.1.0-1.fc4 100% |   7.4 KiB/s | 175.0   B |  00m00s
  [137/146] Removing libdnf5-cli-0:5.4.1. 100% |  21.5 KiB/s |  44.0   B |  00m00s
  [138/146] Removing libblkid-0:2.41.3-12 100% |   6.8 KiB/s |   7.0   B |  00m00s
  [139/146] Removing libselinux-0:3.10-1. 100% |   7.8 KiB/s |   8.0   B |  00m00s
  [140/146] Removing libsepol-0:3.10-1.fc 100% |   5.9 KiB/s |   6.0   B |  00m00s
  [141/146] Removing libuuid-0:2.41.3-12. 100% |   5.9 KiB/s |   6.0   B |  00m00s
  [142/146] Removing libdnf5-0:5.4.1.0-1. 100% |  25.4 KiB/s |  78.0   B |  00m00s
  [143/146] Removing libsmartcols-0:2.41. 100% |   5.9 KiB/s |   6.0   B |  00m00s
  [144/146] Removing systemd-libs-0:259.5 100% |   9.8 KiB/s |  20.0   B |  00m00s
  [145/146] Removing audit-libs-0:4.1.4-1 100% |  16.6 KiB/s |  17.0   B |  00m00s
  [146/146] Removing openssl-libs-1:3.5.5 100% |   7.0   B/s |  39.0   B |  00m05s
  Complete!
  [reset-state] ?? Configuring Fedora distro...
  The operation completed successfully. 
  [tillandsias-provision] vsock_loopback=loaded
  Created symlink '/etc/systemd/system/sockets.target.wants/podman.socket' ƒ+' '/usr/lib/systemd/system/podman.socket'.
  Created symlink '/etc/systemd/system/multi-user.target.wants/tillandsias-headless-fetch.service' ƒ+' '/etc/systemd/system/tillandsias-headless-fetch.service'.
  Created symlink '/etc/systemd/system/multi-user.target.wants/tillandsias-headless.service' ƒ+' '/etc/systemd/system/tillandsias-headless.service'.
  Created symlink '/etc/systemd/system/multi-user.target.wants/tillandsias-headless-ready.service' ƒ+' '/etc/systemd/system/tillandsias-headless-ready.service'.
  Installing Tillandsias: done (overall 50%)
  Starting Fedora Linux: working (overall 50%)
  Starting Fedora Linux: done (overall 66%)
  Connecting: working (overall 66%)
  Downloading Tillandsias: done (overall 83%)
  Connecting: done (overall 100%)
  [reset-state] RESULT: VM Ready - control wire up +
  reset-state: provisioned and ready (exit 0)
  Registered in Installed Software (v56.10.8.1).

  Launching Tillandsias (WSL2 provisioning = --init will run automatically)...
  Tray started. Look for the Tillandsias icon in the notification area.
  (Right-click the icon for the menu; provisioning runs in the background.)


================================================================
  PENDING ACTIONS
================================================================
  PENDING: none
================================================================

== smoke: installer finished after 146s, LASTEXITCODE=0
```
