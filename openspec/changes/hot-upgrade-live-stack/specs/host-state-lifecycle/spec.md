## MODIFIED Requirements

### Requirement: Destructive reset destroys derived state and preserves operator data; guest regimes have a SOFT and a HARD reset

`--reset-state` on every platform SHALL be a SOFT reset, and a SOFT reset
SHALL be a HOT UPGRADE of the running installation: it replaces the host
binary (and, on a guest regime, the guest headless binary) while KEEPING the
running container stack, the VM or distro, and every running forge. It
destroys only STALE derived state — an owned object that no running container
uses and that does not belong to the current version — and SHALL NOT remove,
move or rewrite any item of operator data. Operator request 2026-09-29,
verbatim: "The SOFT RESET should be a quick upgrade of the HOST's tillandsias
binary and the GUEST tillandsias binary, we might not even need to relaunch
the containers."

Motivating measurement (lenovinha, 2026-09-29): a Linux SOFT reset ran
`podman system reset --force`, which destroyed the non-Tillandsias
fedora-toolbox containers `tillandsias-builder` and `tillandsias-nix` (they
share the name prefix) and every running forge; the Vault store survived
(`Verified:KEEP`, 134 files before and after). A SOFT reset therefore SHALL
NOT run `podman system reset` on any platform, and SHALL decide ownership by
the `io.tillandsias.owner` label (see `app-lifecycle`), never by name prefix
alone.

Guest regimes (macOS, Windows) additionally have a HARD reset, `--reset-guest`,
unchanged: "wipe the VM and its guest, which wipes their stores". Linux gains
a HARD tier for the full podman wipe: `podman system reset --force` runs ONLY
under `TILLANDSIAS_INSTALL_RESET=hard` / `--hard-reset` with the same per-run
approval the guest HARD requires (`HARD` typed on a TTY, or
`TILLANDSIAS_HARD_RESET_APPROVED=1` on that invocation). The Linux
`--reset-guest` stays the narrower removal of owned containers, volumes,
secrets and networks; both Linux flags remain SOFT in the sense that neither
touches operator data, but only `--reset-state` keeps the running stack.

SOFT reset, by platform:

- Linux: the new binary takes the singleton lock by UPGRADE HANDOFF (see
  `app-lifecycle`) and ADOPTS every running owned container; stale owned
  objects (exited containers, unreferenced volumes and networks, images
  `localhost/tillandsias-*:v<X>` neither current nor in use) are removed by
  label; shared containers outside the compatibility window are
  drained-then-swapped only when no forge depends on them; `cache/init-build-state.json`
  and `cache/cache_version` are rewritten for the new version; provision
  markers under `state/` are cleared.
- macOS and Windows: the VM / distro is KEPT RUNNING; the headless binary the
  host tray carries (`downloads/bin` staging) is hot-installed into the
  running guest by atomic rename and the daemon re-executed with a kill scope
  that excludes container processes (see `vm-provisioning-lifecycle`); inside
  the guest, the Linux SOFT reset above runs; `vm/` and everything under
  `/root/.tillandsias/{vault,downloads}` in the guest are untouched. Where the
  host tray cannot exit without stopping the guest (a VM hosted in the tray
  process), the host half SHALL report `deferred:vm-in-process` and offer the
  drain-and-relaunch path; it SHALL NOT drain silently.

HARD reset, in addition to SOFT: (guest regimes) `rootfs.img`, `rootfs.qcow2`,
`vmlinuz`, `initramfs.img`, `cidata.iso`, `vm-swap.img`, `console.log` under
`vm/` (macOS); `wsl --unregister tillandsias`, the `.import-complete` marker
(Windows); (Linux) `podman system reset --force`. The guest-resident Vault
store dies with the guest, so a guest HARD SHALL ALSO clear the keyring share
and root token for that store and SHALL say so before destroying. Host-side
`~/.tillandsias/{config,downloads}` are still preserved by HARD.

The KEEP table every SOFT reset honours (paths under `TILLANDSIAS_HOME`):

| item | SOFT | HARD |
|---|---|---|
| running owned containers, their ids and PIDs | KEEP (adopted) | WIPE |
| running forges and the agent sessions inside them | KEEP, never signalled | WIPE |
| images for the current version and any version a running container uses | KEEP | WIPE |
| VM / distro | KEEP, running | WIPE, rebuilt |
| `vault/data`, `vault/audit`, `downloads/`, `config/` | KEEP | KEEP |
| keyring share, root token, install anchor | KEEP | share and token WIPED on a guest HARD; anchor KEEP |
| objects without an `io.tillandsias.owner` label that do not match the legacy name predicate, and any object carrying a toolbox label | never touched | never touched by the binary (the Linux HARD `podman system reset` is the one exception and says so) |

The three Vault-store dispositions (`Verified:KEEP`, `Unverified:KEEP`,
`Absent:REINIT-AT-INIT`), the consent rule (SOFT pre-authorised everywhere,
HARD per-run approval), the installer decision point (an install over an
existing install is an UPDATE and runs SOFT), and `TILLANDSIAS_DESTRUCTIVE_RESET_OK=0`
as the one opt-out are unchanged from the amended text and apply to the
hot-upgrade SOFT as they applied before. An upgrade that cannot honour the
KEEP table SHALL refuse with `refused:upgrade:<reason>`, change nothing, and
name the relaunch path; it SHALL NOT fall back to a stop-everything reset on
its own.

@trace spec:host-state-lifecycle, spec:tillandsias-vault, spec:app-lifecycle, spec:vm-provisioning-lifecycle

#### Scenario: Linux reset-state keeps the Vault store and the unseal share
- **WHEN** `tillandsias --reset-state` runs on Linux with the share in an
  unlocked login keyring and Vault holding `secret/github/token`
- **THEN** `podman system reset --force` SHALL NOT run
- **AND** `~/.tillandsias/vault/data` SHALL still exist with the same content
  digest, and `vault-shamir-share-v1` SHALL still be present
- **AND** the running vault container SHALL be adopted (same container id) or,
  if outside the compatibility window and unused, drained-then-swapped over
  the same store, and `vault-cli read secret/github/token` SHALL return the
  pre-reset token afterwards
- **AND** no harness and no GitHub login prompt SHALL appear on the next forge
  launch.
- Pre-fix result: FAILS on the first clause — `run_reset_state`
  (`main.rs:10172-10175`) runs `podman system reset --force`; the store
  clauses PASS today (1437-qza3; measured 2026-09-29, 134 files before and
  after).

#### Scenario: Linux SOFT reset keeps running forges and foreign containers
- **WHEN** `--reset-state` runs on a Linux host with a forge running an agent
  process, and two toolbox containers named `tillandsias-builder` and
  `tillandsias-nix` running
- **THEN** after the reset the forge container id and the agent PID SHALL be
  unchanged and both toolboxes SHALL still be running
- **AND** the reset SHALL print the owned stale objects it removed and the
  foreign objects it skipped, by name.
- Pre-fix result: FAILS — measured 2026-09-29 on lenovinha: `podman system
  reset --force` removed both toolboxes and every forge.

#### Scenario: A SOFT reset that cannot adopt refuses loudly
- **WHEN** the running instance does not answer the upgrade handoff
- **THEN** the reset SHALL exit non-zero with `refused:upgrade:no-handoff-peer`,
  SHALL send no signal to the running instance, SHALL remove nothing, and
  SHALL print `tillandsias --quit && tillandsias` as the relaunch path.
- Pre-fix result: FAILS — a second instance SIGTERMs the first through the
  singleton lock (`singleton.rs:134-146`) unconditionally.

#### Scenario: Linux HARD requires the per-run approval
- **WHEN** `TILLANDSIAS_INSTALL_RESET=hard` is set on Linux without a TTY and
  without `TILLANDSIAS_HARD_RESET_APPROVED=1`
- **THEN** `podman system reset --force` SHALL NOT run and the reset SHALL
  refuse with `reset: HARD requires per-run approval (TILLANDSIAS_HARD_RESET_APPROVED=1 or --approve-hard-reset)`
- **AND** with the approval present it SHALL announce `reset: HARD`, name the
  toolbox containers it will destroy, and run.
- Pre-fix result: FAILS — no Linux HARD tier exists; `podman system reset
  --force` runs as SOFT with no approval.

#### Scenario: macOS SOFT reset keeps the guest, the store and the downloads
- **WHEN** `tillandsias-tray --reset-state` runs on macOS
- **THEN** `rootfs.img` SHALL NOT be recreated and the VM SHALL NOT reboot
- **AND** the guest's `/usr/local/bin/tillandsias-headless` SHALL be the
  tray's current binary, installed by rename, and `podman ps -q` inside the
  guest SHALL be the same set before and after the daemon re-exec
- **AND** the guest-resident Vault store SHALL be readable with the Keychain
  share, and `~/.tillandsias/downloads` byte-identical.
- Pre-fix result: FAILS — the guest binary is installed only by the boot-time
  fetch oneshot (`vz.rs:1203`), and the Linux SOFT body inside the guest wipes
  the containers.

#### Scenario: Windows SOFT reset keeps the distro, the store and the downloads
- **WHEN** `tillandsias-tray.exe --reset-state` runs on Windows
- **THEN** `wsl --unregister tillandsias` and `wsl --terminate` SHALL NOT run
- **AND** the guest's headless binary SHALL be the tray's current binary,
  installed by rename without `systemctl stop`, and `podman ps -q` inside the
  distro SHALL be the same set before and after the re-exec
- **AND** the guest-resident Vault store SHALL be readable with the Credential
  Manager share, and `%USERPROFILE%\.tillandsias\downloads` byte-identical.
- Pre-fix result: FAILS — `inject_stale_guest_wiring` (`wsl_lifecycle.rs:1124`)
  stops the unit before overwriting the ELF; container survival is unmeasured.

#### Scenario: Reset announces the two sets and which kind it is
- **WHEN** any platform reset runs
- **THEN** `announce_reset_plan` SHALL print, before touching anything,
  `reset: SOFT` or `reset: HARD`, the stale set it will remove, the running
  set it will adopt (SOFT) or destroy (HARD), the foreign set it will skip,
  and the operator-data set it will preserve.
- Pre-fix result: FAILS — the announcement has no adopted set and no skipped
  set.
