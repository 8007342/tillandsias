## 1. Host single root (Linux) — order 1874-yix9

- [ ] 1.1 Add a scoped-HOME fixture that runs init + one forge launch/remove and lists Tillandsias-created paths outside `<root>` and the exempt list; watch it fail on today's code
- [ ] 1.2 Introduce `TILLANDSIAS_HOME` resolution and the subtree layout from design D1
- [ ] 1.3 Give Tillandsias its own rootless podman store (graphroot, runroot, volume path) under `<root>/podman`, replacing both current stores, without editing `~/.config/containers`; one rebuild of every image
- [ ] 1.4 Move `~/.cache|.local/state|.config/tillandsias` writers; old paths wiped, not migrated (vault rebuilt)
- [ ] 1.5 Tray "Open storage folder" and storage report

## 2. Forge L1 scratch layer — order 1875-rebn

- [ ] 2.1 Fixture: forge create argv mounts a per-lane scratch volume at `/home/forge/scratch`, removal deletes it, `TMPDIR` is under it
- [ ] 2.2 Create/remove the volume next to `prepare_forge_ram_workspace` / `remove_source_volume_if_present`
- [ ] 2.3 Move `TMPDIR` in `lib-common.sh` from `$PROJECT_CACHE/tmp` to L1

## 3. Forge L2 reusable cache paths and wipe rule — order 1876-ajcs

- [ ] 3.1 Fixture: agent shell env has `GOPATH`, `GOMODCACHE`, `GEM_HOME`, `PUB_CACHE` under `$TILLANDSIAS_PROJECT_CACHE`; corrupted stamp subtree is recreated empty
- [ ] 3.2 Export the paths; per-subtree stamp; wipe-on-mismatch
- [ ] 3.3 Relate to 1865-wv58 (ruby shim) — no duplicate fix

## 4. Mandatory swap — order 1877-maph

- [ ] 4.1 Fixture: a `/proc/swaps` with only zram (and with none) makes the Linux tray refuse to start with plain enable instructions; disk swap ≥ threshold starts
- [ ] 4.2 Refuse-to-start + instructions naming `tillandsias --swap on`; macOS VM and WSL force the known-good swap config

## 5. Worktree eviction and disk-aware skills — order 1878-2cwt

- [ ] 5.1 Fixture: scratch repo with a pushed clean worktree, an unpushed one and a dirty one under a simulated low threshold; only the pushed one is evicted; unreachable threshold yields `refused:disk-low`
- [ ] 5.2 One binary subcommand (no new shell; carried shell-to-lua obligation)
- [ ] 5.3 Wire into every skill in design D5; add the startup-context disk line (coordinates with 1866-ubtc, which owns the in-forge source tmpfs pruning)

## 6. Research: macOS (peer task)

- [ ] 6.1 Pick the macOS root. Candidates: `~/Library/Application Support/Tillandsias` (single tree, Apple-sanctioned) vs `~/Library/Caches` + `Application Support` split vs `~/.tillandsias`. Weigh Time Machine exclusion (`tmutil addexclusion`, `com.apple.metadata:com_apple_backup_excludeItem`), iCloud/Spotlight indexing, and Finder discoverability. Recommend one root and the exempt list (app bundle, LaunchAgents plist).
- [ ] 6.2 Inventory everything the macOS tray writes today: VM bundle/disk image, EFI vars, machine-id, sockets, logs (`~/Library/Logs`?), caches, keychain items, `/tmp` use. Paths, sizes, creator symbol.
- [ ] 6.3 Map the four forge layers onto the Virtualization.framework guest: what backs L0 tmpfs and the overlay inside the guest; is the guest disk a sparse raw image on APFS (and does deleting files inside reclaim host space — TRIM/discard through virtio-blk)? Where should L1 (per-forge, deleted with the forge) and L2 (survives restarts) live: guest disk vs separate attached images vs virtiofs share.
- [ ] 6.4 Swap: does the guest have disk swap? Memory balloon behaviour; recommend a guest swap file size and the host-side warning signal.
- [ ] 6.5 Re-run the "shim downloads land on the ramdisk" check inside the macOS guest (`df -hT` on `/home/forge/src`, `/tmp`, overlay, `$HOMEBREW_CACHE`, `$TMPDIR`) and report.
- [ ] 6.6 Free-space probe for D4 inside the guest and on the host APFS volume (purgeable space semantics); which number to compare.

## 7. Research: Windows (peer task)

- [ ] 7.1 Pick the Windows root. Candidates: `%LOCALAPPDATA%\Tillandsias` (non-roaming, per-user) vs `%USERPROFILE%\.tillandsias`. Confirm the WSL distro VHDX (`ext4.vhdx`) can be placed under the root via `wsl --import <name> <root>\wsl <tar>`. Exempt list (install dir, Start-menu shortcut, registry run key, `.wslconfig` edits).
- [ ] 7.2 Inventory everything the Windows tray writes today: WSL distro(s) and their VHDX location, `%LOCALAPPDATA%`/`%APPDATA%`/`%TEMP%` use, `.wslconfig`, logs, named pipes, registry keys. Paths, sizes, creator symbol.
- [ ] 7.3 Map the four forge layers onto WSL2: tmpfs inside the distro vs the WSL VM memory cap (`.wslconfig memory=`); whether the VHDX shrinks after deletes (`sparseVhd=true`, `wsl --manage --set-sparse`); where L1/L2 live (same VHDX vs a second attached VHDX).
- [ ] 7.4 Swap: WSL2 `swap=` / `swapFile=` in `.wslconfig` (default 25 % of RAM, on the host disk). Recommend size, placement under the root, and the tray warning when `swap=0`.
- [ ] 7.5 Re-run the ramdisk-download check inside the WSL forge and report.
- [ ] 7.6 Free-space probe for D4: host NTFS volume holding the VHDX vs ext4 free inside it; which one gates eviction.

## 8. Cross-platform acceptance

- [ ] 8.1 Each platform's peer returns: root path, inventory table, layer mapping, swap recommendation, free-space probe — in the shape of design.md tables

## 9. Download manifest — order 1891-dlmf

- [ ] 9.1 Manifest of every large download with size and class (non-negotiable vs hot-deletable); fixture asserts every image/model fetch site is listed

## 10. Mount-intent audit — order 1892-mtau

- [ ] 10.1 Reword forge affordances, docs, startup context and tooling so every mount states its intent and limits

## 11. Operator rulings 2026-10-25 (resolved)

- [x] 11.1 Root on Linux: visible `~/.tillandsias`
- [x] 11.2 Own rootless podman store replaces both current stores; one image rebuild
- [x] 11.3 Vault and CA move out of cache; wiped, not migrated
- [x] 11.4 Swap is mandatory: Linux tray refuses to start; macOS/WSL forced config, floor tiers included
- [x] 11.5 L1 cap: generous, sized from free disk at create, with a floor
