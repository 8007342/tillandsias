<!-- @trace spec:host-state-lifecycle -->
# host-state-lifecycle Specification

## Status

active

Filed 2026-09-27 (order 1437-8c6p) from the operator's directives of the same
day. No spec owned `--reset-state`, `--reset-guest`,
`TILLANDSIAS_DESTRUCTIVE_RESET_OK`, the download cache as a unit, or an
uninstall that removes everything; `environment-runtime` owns the ACCOUNTABILITY
of the uninstall script (print before delete, report after) and keeps it.

AMENDED 2026-09-27, same day (order 1438-pk9j), from the operator's answers to
the five open questions of 1437-8c6p: (1) survival of the Vault store REQUIRES
an unlocking keyring — no persisted fallback share; (2) guest regimes get a
SOFT and a HARD reset; (3) every Tillandsias-owned file lives under
`~/.tillandsias/`; (4) uninstall leaves ZERO traces and prompts `[y/N]` before
removing `~/.tillandsias/`. Each ruling is quoted where it lands below.

## Purpose

State what a destructive reset destroys, what it preserves, and what only a
manual uninstall removes — on every platform, by named path — so that
"reset is the baseline" and "credentials survive wipes" hold at the same time.

Two operator rulings meet here and this spec is how they coexist:

- **Reset is the baseline** (2026-09-13, order 900-z3kv, recorded in
  `plan/issues/fleet-restart-2026-09-12.md`): "the platform prefers idempotency
  over legacy support; anything nuked on the way was meant to be nuked, like
  old configs from stale code; the way to exercise the correct new code is a
  system reset as the baseline, which is why `podman system reset --force` is
  not only allowed but preferred".
- **Credentials and downloads survive wipes** (2026-09-27, verbatim): "when we
  wipe all containers and images on all hosts, the destructive reset is meant
  to wipe the vault and other images, but we want to KEEP THE CREDENTIALS,
  likely just the VAULT'S STORE, since a newly created vault using the unlock
  key still present in the session's keyring should still be able to unlock
  and read the credentials"; "the VAULT STORE and the DOWNLOAD CACHE should
  survive system wipes and recreations. Only a manual `tillandsias --uninstall`
  should wipe everything including the vault store, and any downloaded caches
  or ollama models we've downloaded."

They coexist by classifying host state into two sets. **Derived state** is
anything the release artefact can rebuild from itself plus the network:
containers, images, named volumes, networks, podman secrets, provision
markers, `init-build-state.json`, `cache_version`, and — under a HARD reset
only — the guest rootfs or WSL distro. Reset destroys ALL of it,
unconditionally, and rebuilds it — that is the baseline, and it stays
preferred to repair. **Operator data** is what the operator paid for with a
sign-in or a download: the Vault store and its unseal material, the
downloads (models, rootfs tarballs, toolchains, prebuilt tools), and
Tillandsias-owned configuration files. Reset never touches operator data;
only `--uninstall` does. The 2026-09-27 directive therefore SUPERSEDES the
choice recorded under 900-z3kv (option (a): "the documented reset clears the
host-held share") for the credential subject ONLY; the idempotency principle
behind 900-z3kv is unchanged and this spec restates it for derived state.

Cross-references:
- `tillandsias-vault` — where the store and the unseal material live per
  platform, and the fresh-Vault-reads-old-store scenarios.
- `cache-recovery-mechanism` — the cache directory under `~/.tillandsias/`.
- `inference-container` — the model directory is a download.
- `environment-runtime` — accountable uninstall (print, delete, report) and
  the global config file's new home.
- `podman-idiomatic-patterns`, `wsl-runtime` — Tillandsias-owned configs.

## Requirements

### Requirement: Everything Tillandsias owns on a host lives under `~/.tillandsias/`, and a first launch migrates the legacy roots there
<!-- req-id: aed53110 -->

Operator ruling 2026-09-27, verbatim: "keep all our configs and downloaded
files in ~/.tillandsias/ for a user to easily find them, snoop around, and
wipe them afterwards." Every file Tillandsias writes on a host outside the
installed binary, its launcher registrations and the OS keyring SHALL live
under ONE root, `TILLANDSIAS_HOME`, which defaults to `~/.tillandsias` on
Linux and macOS and `%USERPROFILE%\.tillandsias` on Windows, and inside a
guest to `/root/.tillandsias`. The XDG variables, `~/Library/*` and
`%LOCALAPPDATA%` / `%APPDATA%` SHALL no longer be consulted for Tillandsias
roots except by the migration below. The layout:

```
~/.tillandsias/
  config/           Tillandsias-owned configuration. config.toml (the global
                    config), containers/{containers.conf,registries.conf,
                    storage.conf}, wslconfig.toml. Operator data.
  downloads/        Everything fetched from the network, and the manifest.
                    manifest.json, models/ (ollama weights and the engine),
                    rootfs/ (tarballs, qcow2), bin/ (staged guest binaries),
                    tools/ (prebuilt forge tools), chromium/, nix/ (store
                    paths served to the enclave). Operator data.
  vault/            data/ (the Vault file backend), audit/. Operator data.
  cache/            Derived, rebuildable: packages/, forge-projects/,
                    nix-cache/, runtime/<version>/ (assets extracted from
                    the binary), init-build-state.json, cache_version.
  state/            logs/, metrics-archive/, capabilities.json, provision
                    and crash-loop markers, guest-ready.json, guest-wiring.json.
  vm/               Guest regimes only: rootfs.img, vmlinuz, initramfs.img,
                    cidata.iso, vm-swap.img, nvram.bin (macOS); the distro
                    install root and wsl-swap.vhdx (Windows).
```

Inside a guest the same layout applies under `/root/.tillandsias`, and
`downloads/` SHALL be the host's `downloads/` shared into the guest wherever
a host share exists (macOS already shares the model cache; Windows shares
what 1437-3iux measures), so a download made from either side is one set of
bytes.

Every read of a Tillandsias root SHALL go through one resolver per crate
family (`tillandsias_core::home` or its successor) that honours
`TILLANDSIAS_HOME`; fixtures set that variable and never a real home. The
operator's words on state: "the ephemeral/idempotent approach should take
care transparently of launching correctly from any state" — so a launch that
finds any mix of the legacy roots and the new root SHALL converge to the new
root and then behave as a normal launch.

Migration, on first launch of a binary that carries this layout: for each
legacy root (Linux: `$XDG_CACHE_HOME/tillandsias` or `~/.cache/tillandsias`,
`~/.local/share/tillandsias`, `~/.config/tillandsias`, `~/.local/state/tillandsias`;
macOS: `~/Library/Application Support/tillandsias`, `~/Library/Caches/tillandsias`,
`~/Library/Logs/tillandsias`; Windows: `%LOCALAPPDATA%\tillandsias`,
`%APPDATA%\tillandsias`) that exists, move each known child to its new home
(`vault-data` → `vault/data`, `vault-audit` → `vault/audit`, `models` →
`downloads/models`, `packages` and `forge-projects` → `cache/`, `runtime` →
`cache/runtime`, `config.toml` → `config/config.toml`, the VM directory
contents → `vm/`, logs → `state/logs`, and so on for every child the audit
in `plan/issues/operator-directives-reset-survivors-and-harness-bypass-2026-09-27.md`
names). A move is a rename when the two are on one filesystem and a
copy-verify-delete otherwise; a child that already exists at the destination
is left alone and the legacy copy removed only when byte-identical, else
kept beside it as `<name>.legacy-<ts>` and named on stderr. An emptied legacy
root is removed. The migration is idempotent and prints one line per moved
child. The Vault store moves as bytes with no re-initialisation; the keyring
share is untouched.

@trace spec:host-state-lifecycle, spec:cache-recovery-mechanism, spec:environment-runtime

#### Scenario: A fresh host creates the layout
- **WHEN** Tillandsias runs for the first time on a host with no legacy roots
- **THEN** `~/.tillandsias/{config,downloads,vault,cache,state}` SHALL exist
  after `--init` (plus `vm/` in a guest regime)
- **AND** no file SHALL have been written under `~/.cache/tillandsias`,
  `~/.local/share/tillandsias`, `~/.config/tillandsias`, `~/.local/state/tillandsias`,
  `~/Library/*/tillandsias`, `%LOCALAPPDATA%\tillandsias` or `%APPDATA%\tillandsias`.
- Pre-fix result: FAILS — every one of those legacy roots is written today.

#### Scenario: A legacy host is migrated once and converges
- **WHEN** a host has a populated `~/.cache/tillandsias` (store, models,
  packages) and `~/.config/tillandsias/config.toml`, and the new binary
  launches
- **THEN** after the launch the store is at `~/.tillandsias/vault/data`, the
  models at `~/.tillandsias/downloads/models`, the config at
  `~/.tillandsias/config/config.toml`, with the same content digests
- **AND** the legacy roots SHALL be gone
- **AND** a second launch SHALL move nothing and print nothing about
  migration
- **AND** the Vault SHALL unseal over the moved store with the existing
  keyring share.
- Pre-fix result: FAILS — no migration exists.

#### Scenario: A mixed state converges without prompting
- **WHEN** a host has both a partially populated `~/.tillandsias` and a
  legacy root (an interrupted migration, or two binary versions used in turn)
- **THEN** the launch SHALL complete the migration, keep the newer of any
  duplicate by the rule above, name every kept `.legacy-<ts>` copy on stderr,
  and proceed
- **AND** SHALL NOT ask the operator anything.

#### Scenario: `TILLANDSIAS_HOME` redirects every root
- **WHEN** `TILLANDSIAS_HOME=/tmp/x` is set and any Tillandsias command runs
- **THEN** every path the command reads or writes SHALL be under `/tmp/x`
- **AND** a fixture that runs a hermetic `--init` under it SHALL find nothing
  written outside it (this is the seam every destructive fixture uses).

### Requirement: Destructive reset destroys derived state and preserves operator data; guest regimes have a SOFT and a HARD reset
<!-- req-id: df90fe0e -->

`--reset-state` on every platform SHALL be a SOFT reset: it destroys every
item of derived state and SHALL NOT remove, move or rewrite any item of
operator data. The reset SHALL remain the preferred remedy for a broken
substrate: the code path MUST NOT grow a "repair instead of reset" branch to
protect operator data, because operator data is not inside the thing being
reset.

Guest regimes (macOS, Windows) additionally have a HARD reset, `--reset-guest`.
Operator ruling 2026-09-27, verbatim: HARD is today's behaviour, "wipe the VM
and its guest, which wipes their stores"; SOFT is "the VM and the FEDORA GUEST
are kept, but the tillandsias binary and the Tillandsias STORES (Vault,
Caches, Downloaded stuff, etc) is kept. We can still wipe the previous
containers, and inject the new updated tillandsias binary, and let it
initialize the containers in the guest from scratch, as if it were doing in a
native linux 'reset' which preserves stores." On Linux there is no guest, so
`--reset-guest` stays the narrower soft reset it is today (containers,
volumes, secrets, networks; no `podman system reset`); both Linux flags are
SOFT.

SOFT reset, by platform:

- Linux: every `tillandsias-*` container, named volume, secret and network;
  `podman system reset --force` where the platform reset already uses it;
  `cache/init-build-state.json`, `cache/cache_version`, provision markers
  under `state/`.
- macOS and Windows: the VM / distro is KEPT and booted; the headless binary
  in the guest is replaced by the one the host tray carries (`downloads/bin`
  staging); inside the guest, the Linux SOFT reset above runs; guest-side
  `state/` markers are cleared; `vm/` and everything under `/root/.tillandsias/{vault,downloads}`
  in the guest are untouched.

HARD reset (guest regimes only), in addition to SOFT: `rootfs.img`,
`rootfs.qcow2`, `vmlinuz`, `initramfs.img`, `cidata.iso`, `vm-swap.img`,
`console.log` under `vm/` (macOS); `wsl --unregister tillandsias`, the
`.import-complete` marker (Windows). The guest-resident Vault store dies with
the guest, so HARD SHALL ALSO clear the keyring share and root token for that
store (a share for a dead store delivered into a new guest is the 803-49re
incident) and SHALL say so before destroying. Host-side `~/.tillandsias/{config,downloads}`
are still preserved by HARD: they are host files, and the rebuilt guest
reuses the downloads.

The operator-data set every SOFT reset preserves (paths under
`TILLANDSIAS_HOME`; legacy paths are what the migration reads):

- `vault/data`, `vault/audit`, `downloads/` and every path the manifest
  lists, `config/`; on Linux also `cache/nix-store` when present.
- Keyring: `vault-shamir-share-v1`, `vault-root-token-v1` and the install
  anchor (`installation-uuid-v1` on Linux, `tillandsias-vm-uuid` on macOS
  and Windows) under service `tillandsias` (Secret Service, Keychain,
  Credential Manager).
- Windows: the Tillandsias-owned block of `%USERPROFILE%\.wslconfig`.

Survival of the Vault store has ONE precondition. Operator ruling 2026-09-27,
verbatim: "the presence of an unlocking keyring should be a requirement to
survive the vault store." A host whose share is not in an unlocking keyring
(Secret Service with the login keyring unlocked, macOS Keychain, Windows
Credential Manager; for a guest, the host keyring that delivers the share
over the control channel) has NO persisted fallback share — the fallback
file is never written to disk that outlives the process (1118-fqfk's
direction, now ruled). A SOFT reset SHALL NOT itself delete any store (reset
bodies call no credential clearer); what it does is ANNOUNCE one of three
dispositions, decided by asking the keyring before destroying anything:

| keyring answer at reset time | disposition | announcement |
|---|---|---|
| reachable, holds a 32-byte share | `Verified:KEEP` | `reset: Vault store kept (Verified:KEEP) — share vault-shamir-share-v1 present` |
| UNREACHABLE (Secret Service down, D-Bus timeout, locked keyring that cannot be asked) and no fallback share | `Unverified:KEEP` | `reset: keyring unreachable — Vault store kept unverified (Unverified:KEEP); it unseals at next init if the share is there, else init re-initialises it and says so` |
| reachable, holds no share | `Absent:REINIT-AT-INIT` | `reset: no unlocking keyring holds vault-shamir-share-v1 — the Vault store cannot survive this reset and will be re-initialised at next init` |

AMENDED 2026-09-27 (order 1443-bs9z), operator verbatim: "Unverified:KEEP is
ok for a soft reset, let's see how that spills on the other cases." The
middle row is that ruling: an unreachable keyring is not evidence of an
absent share, so a SOFT reset keeps the store and says it could not verify
it; the partial-init guard at the next init is the decider, with its own
loud line. The `Unverified:KEEP` token is an interface (fixtures and the
tray read it); do not respell it.

OPEN QUESTION, not decided here: what a HARD reset does when the keyring is
unreachable. HARD clears the share for the store it destroys; with the
keyring unreachable it cannot clear it, so either it refuses (no HARD
without a reachable keyring — a stale share left behind is the 803-49re
shape) or it proceeds and records the unverified clearing for the next
launch to retry. The operator has not ruled; the HARD scenarios below
assume a reachable keyring, and a HARD reset that finds the keyring
unreachable SHALL stop and print `reset: HARD refused — keyring unreachable,
share cannot be cleared (open question, host-state-lifecycle)` until the
ruling lands, because refusing is the reversible choice.

`TILLANDSIAS_DESTRUCTIVE_RESET_OK=0` remains the ONE opt-out and keeps its
meaning: the reset is skipped and init runs. No new environment variable
SHALL be added to make a reset preserve operator data, because preserving it
is the only SOFT behaviour. `TILLANDSIAS_RESET_KEEP_MODELS` becomes a no-op
that is accepted and ignored with one stderr line naming this spec.

Consent, AMENDED 2026-09-27 (1443-bs9z), operator verbatim: "Forges should
keep pre-authorizing SOFT RESET always. HARD RESET should require explicit
approval each time." A SOFT reset needs NO consent: it destroys only derived
state, so a forge (`TILLANDSIAS_HOST_KIND=forge`), a smoke skill, and the
installer's update path run it without asking and without any approval
variable, and nothing SHALL ever add a prompt to it.

AMENDED 2026-10-08 (1559-9uvb), operator verbatim: "we do not ask end users
to do power user stuff. That's our guideline. An install prompt asking for
destructive cases should not be an acceptable case. End user is NOT a power
user. No prompts like those, we make all the decisions for them, on their
behalf, for their best interests. So SOFT reset is the default only and
forever. A power user wanting to do a hard reset should be capable of
figuring out where to place a flag and which flag, we do not need to print
any power user messages during install, at all. Install should be for END
USER (NOT POWER USER) and be a pretty installer, rather than an
informational/debugging installer. As frictionless as possible for end
users." A HARD reset therefore runs ONLY on an explicit, NON-INTERACTIVE,
per-run approval: the binary's `--approve-hard-reset` argument, or
`TILLANDSIAS_HARD_RESET_APPROVED=1` present on THAT invocation's environment.
NOTHING EVER PROMPTS: no binary, installer or skill asks for a typed word or
any other confirmation, and without the approval a HARD reset refuses
non-interactively, exit 1, before touching anything. The approval is never
read from a config file, a settings file, a forge image, a persisted
environment or a previous run, and a forge SHALL never carry the approval
variable (the forge-launch argv builders SHALL strip it). The 1004-vsh2
per-run-consent ruling for destructive smokes stands and is the same shape.
(Superseded: the 2026-09-27 wording that HARD asks
`... Type HARD to continue:` on a TTY.)

Installers, AMENDED 2026-10-08 (same ruling): an install, fresh or over an
existing install, SHALL run the SOFT reset (`--reset-state`) and ONLY the
SOFT reset, always. Installers SHALL NOT offer a reset kind, SHALL NOT
prompt, and SHALL NOT print power-user or diagnostic text about resets or
flags (no reset-kind line, no flag names). The HARD path is the binary's
power-user CLI above and is never reached from an installer. The escape
`TILLANDSIAS_DESTRUCTIVE_RESET_OK=0` is honoured by the binary itself. The
1286-4437 wording "the reset destroys the vault store, mirrors and images" is
superseded for the vault store. (Superseded: the 2026-09-27 installer
decision point with `TILLANDSIAS_INSTALL_RESET=hard`, `--hard-reset` and a
first line naming the kind.)

@trace spec:host-state-lifecycle, spec:tillandsias-vault, spec:inference-container

#### Scenario: Linux reset-state keeps the Vault store and the unseal share
- **WHEN** `tillandsias --reset-state` runs on Linux with the share in an
  unlocked login keyring and Vault holding `secret/github/token` and
  `secret/claude/oauth`
- **THEN** `podman system reset --force` SHALL run and every image, container,
  volume, secret and network SHALL be gone
- **AND** `~/.tillandsias/vault/data` SHALL still exist with the same content
  digest as before the reset
- **AND** the keyring entry `vault-shamir-share-v1` SHALL still be present
- **AND** the following `--init` SHALL start a freshly built Vault container
  over that store, unseal it with that share, and `vault-cli read
  secret/github/token` from the git service SHALL return the pre-reset token
- **AND** no harness and no GitHub login prompt SHALL appear on the next forge
  launch.
- Pre-fix result: FAILS — `run_reset_state` calls
  `clear_host_vault_credentials`, which deletes the share, the root token and
  the store; the next launch prompts for Claude and GitHub sign-in (operator
  observation 2026-09-27, the incident behind this spec).

#### Scenario: A host whose keyring holds no share does not keep the store
- **WHEN** `--reset-state` runs on a Linux host whose Secret Service answers
  and holds no `vault-shamir-share-v1`, so the share was only ever held in
  memory
- **THEN** the reset SHALL print the `Absent:REINIT-AT-INIT` line above
  before destroying anything
- **AND** no fallback share file SHALL exist anywhere on disk before or after
- **AND** the next `--init` SHALL re-initialise Vault and print the
  partial-init line naming the lost store
- **AND** the reset body itself SHALL still call no credential clearer.
- Pre-fix result: FAILS — `keychain_set_blocking` writes
  `fallback_vault-shamir-share-v1` to the cache directory and the reset
  preserves nothing anyway; after 1437-qza3's first local cut (lenovinha,
  2026-09-27) the fallback file was PRESERVED across reset, which this ruling
  reverses.

#### Scenario: SOFT reset with the keyring unreachable keeps the store unverified
- **WHEN** `--reset-state` runs on a Linux host whose Secret Service cannot
  be asked (daemon absent, D-Bus timeout, locked and unpromptable) and no
  fallback share exists
- **THEN** the reset SHALL print the `Unverified:KEEP` line above before
  destroying anything
- **AND** `~/.tillandsias/vault/data` SHALL be byte-identical afterwards
- **AND** the reset SHALL NOT prompt and SHALL NOT wait for the keyring
  beyond the existing 2-second `with_keyring_timeout`
- **AND** when the keyring is reachable again at the next `--init` and holds
  the share, Vault SHALL unseal over the kept store; when it holds none, the
  partial-init guard SHALL re-initialise with its loud line.
- Pre-fix result: FAILS — nothing distinguishes unreachable from absent
  today; both fall through to `keychain_set_blocking`'s fallback file, and
  the reset then clears the store regardless.

#### Scenario: SOFT reset is pre-authorised everywhere, HARD never asks
- **WHEN** `--reset-state` runs inside a forge, from a smoke skill, or from
  an installer
- **THEN** it SHALL run with no prompt and no approval variable
- **AND** **WHEN** `--reset-guest` (HARD) runs on a guest regime without
  `--approve-hard-reset` and without `TILLANDSIAS_HARD_RESET_APPROVED=1` on
  that invocation, whether or not a TTY is attached
- **THEN** it SHALL NOT prompt, SHALL refuse with `reset: HARD requires per-run approval
  (TILLANDSIAS_HARD_RESET_APPROVED=1 or --approve-hard-reset)` and exit 1
  before touching anything
- **AND** with either approval it SHALL proceed without asking anything
- **AND** a forge-launch argv builder SHALL strip `TILLANDSIAS_HARD_RESET_APPROVED`
  from the container environment, proven by a fixture arm that sets it on the
  host and reads the container's `/proc/1/environ`.
- Pre-fix result: FAILS — today's `--reset-guest` on both trays destroys the
  guest with no approval of any kind, and `TILLANDSIAS_DESTRUCTIVE_RESET_OK`
  (an opt-out, not an approval) is the only gate.

#### Scenario: Linux reset-guest keeps the Vault store
- **WHEN** `tillandsias --reset-guest` runs on Linux
- **THEN** `reset_guest_wipe_paths` SHALL return no path under operator data
- **AND** `vault/data` and `downloads/models` SHALL be untouched.
- Pre-fix result: FAILS — `reset_guest_wipe_paths` returns the store path.

#### Scenario: Reset announces the two sets and which kind it is
- **WHEN** any platform reset runs
- **THEN** `announce_reset_plan` SHALL print, before destroying anything,
  `reset: SOFT` or `reset: HARD`, the derived set it will destroy and the
  operator-data set it will preserve, naming the Vault store, `downloads/`
  and the keyring entries explicitly
- **AND** the preserved list SHALL be the same list this requirement names.

#### Scenario: macOS SOFT reset keeps the guest, the store and the downloads
- **WHEN** `tillandsias-tray --reset-state` runs on macOS
- **THEN** `rootfs.img` SHALL NOT be recreated (same inode or same digest)
- **AND** the guest SHALL boot with the tray's current headless binary
  injected, run the Linux SOFT reset inside, and re-initialise its containers
- **AND** the guest-resident Vault store SHALL be readable by the freshly
  created Vault container with the Keychain share
- **AND** `~/.tillandsias/downloads` SHALL be byte-identical, with or without
  `TILLANDSIAS_RESET_KEEP_MODELS`
- **AND** Keychain items `vault-shamir-share-v1` and `vault-root-token-v1`
  SHALL still be present.
- Pre-fix result: FAILS — `run_reset_state` wipes the provisioned VM
  artefacts, clears both Keychain items and removes the caches directory
  unless the keep-models variable is set.

#### Scenario: macOS HARD reset destroys the guest and says the store goes with it
- **WHEN** `tillandsias-tray --reset-guest` runs on macOS with the per-run
  approval given (`--approve-hard-reset`, or `TILLANDSIAS_HARD_RESET_APPROVED=1`
  on this invocation) and the Keychain reachable
- **THEN** the announcement SHALL say `reset: HARD` and that the Vault store
  inside the guest and its Keychain share will be removed
- **AND** `vm/` contents SHALL be recreated by provisioning
- **AND** `~/.tillandsias/{config,downloads}` SHALL be byte-identical
- **AND** after provisioning, Vault SHALL be freshly initialised and every
  harness SHALL prompt for sign-in once (the expected cost of HARD).
- Pre-fix result: passes for the wipe (positive control: this is today's
  `reset_guest_main`), FAILS for the announcement and for preserving the
  caches directory.

#### Scenario: Windows SOFT reset keeps the distro, the store and the downloads
- **WHEN** `tillandsias-tray.exe --reset-state` runs on Windows
- **THEN** `wsl --unregister tillandsias` SHALL NOT run
- **AND** the distro SHALL boot with the tray's current headless binary
  injected, run the Linux SOFT reset inside, and re-initialise its containers
- **AND** the guest-resident Vault store SHALL be readable by the freshly
  created Vault container with the Credential Manager share
- **AND** `%USERPROFILE%\.tillandsias\downloads` SHALL be byte-identical
- **AND** Credential Manager targets `vault-shamir-share-v1` and
  `vault-root-token-v1` SHALL still be present.
- Pre-fix result: FAILS — `reset_state_once` unregisters the distro, calls
  `clear_guest_vault_credentials` and removes the cache directory.

#### Scenario: Windows HARD reset destroys the distro and says the store goes with it
- **WHEN** `tillandsias-tray.exe --reset-guest` runs on Windows with the
  per-run approval given (`--approve-hard-reset`, or `TILLANDSIAS_HARD_RESET_APPROVED=1`
  on this invocation) and Credential Manager reachable
- **THEN** the announcement SHALL say `reset: HARD` and that the Vault store
  inside the distro and its Credential Manager share will be removed
- **AND** `wsl --unregister tillandsias` SHALL run and provisioning SHALL
  re-import
- **AND** `%USERPROFILE%\.tillandsias\{config,downloads}` SHALL be
  byte-identical.
- Pre-fix result: passes for the wipe and the clearing (positive control:
  today's `reset_state_once`), FAILS for the announcement and for preserving
  the downloads.

#### Scenario: Installers run SOFT only, never prompt, and print no power-user text
- **WHEN** `scripts/install.sh`, `scripts/install-macos.sh` or
  `scripts/install-windows.ps1` runs, fresh or over an existing install,
  whatever `TILLANDSIAS_INSTALL_RESET` or any other variable says
- **THEN** it SHALL run `--reset-state` (SOFT) and never `--reset-guest`
- **AND** it SHALL NOT prompt for anything about the reset, SHALL NOT accept a
  reset-kind argument, and SHALL NOT print a reset-kind line or any flag name
  (operator ruling 2026-10-08, quoted above)
- Pre-fix result: FAILS — the 2026-09-27 shape offered a HARD kind through
  `TILLANDSIAS_INSTALL_RESET=hard` and printed a reset-kind first line.

#### Scenario: The opt-out still opts out of everything
- **WHEN** `TILLANDSIAS_DESTRUCTIVE_RESET_OK=0` is set and either reset runs
- **THEN** nothing in either set SHALL be removed
- **AND** the run SHALL print `RESET_SKIPPED_LINE` and proceed to init
- **AND** this behaviour is unchanged from today (positive control).

#### Scenario: A store without its share is still rebuilt, loudly
- **WHEN** `vault/data` exists but no 32-byte Shamir share is in the keyring
- **THEN** the partial-init guard in `launch_vault_container` SHALL remove the
  store and initialise a fresh one, because an unreadable store preserves
  nothing
- **AND** it SHALL print one line naming the store path, the missing share
  name, and that every credential in the store is lost
- **AND** the reset itself SHALL NOT be the thing that removed the share
  (SOFT), or SHALL have announced it (HARD).

### Requirement: Every download is recorded in one manifest under `~/.tillandsias/downloads/`
<!-- req-id: c766b106 -->

Every artefact Tillandsias fetches from the network onto the host — rootfs
tarballs and qcow2 images, the headless binary staged for a guest, prebuilt
forge tools, the host Chromium, nix store paths, and the model directory —
SHALL be written under `~/.tillandsias/downloads/` and recorded in ONE
manifest file, `~/.tillandsias/downloads/manifest.json`, through ONE
recording function in `tillandsias-core`. Each entry SHALL carry the path
relative to `downloads/` (a file or a directory root), the kind, the source
URL or producer name, the recorded size or digest when known, and the
recording timestamp. Entries whose contents are produced inside a container
onto a bind mount (the model directory) SHALL be recorded once as a
directory root by the host code that creates the mount. The manifest SHALL
be append-mostly: a re-download of the same path replaces its entry; nothing
else edits it. AMENDED 2026-09-27 (1438-pk9j): the manifest moved from
`<cache>/downloads.manifest.json` to the `downloads/` directory of the single
root, and entries are relative so the folder can be inspected or moved as a
unit — the operator's reason for one folder.

The operator's words: "we'll need a manifest in our download cache to make
sure we remove everything we download, likely just contained in our
.tillandsias downloads, configs, and caches folder."

@trace spec:host-state-lifecycle, spec:cache-recovery-mechanism

#### Scenario: A download appends an entry
- **WHEN** any host code path finishes writing a downloaded artefact to disk
- **THEN** the manifest SHALL contain an entry whose path is that artefact
  before the function that downloaded it returns success
- **AND** the entry SHALL be readable by `tillandsias --diagnose` (or the
  platform tray's diagnose mode) as a `downloads:` section listing every
  path and whether it currently exists.
- Pre-fix result: FAILS — no manifest exists; the closest records are
  `init-build-state.json` (built images only) and `runtime/<ver>/manifest.json`
  (embedded assets only).

#### Scenario: Coverage is measurable
- **WHEN** a hermetic `--init` completes under a fresh `TILLANDSIAS_HOME`
- **THEN** every regular file under `downloads/` larger than 1 MiB SHALL be
  covered by a manifest entry (itself, or a directory-root entry that is its
  ancestor)
- **AND** no file larger than 1 MiB that came from the network SHALL exist
  under `cache/` or `state/` (a download outside `downloads/` is the defect
  the layout exists to prevent)
- **AND** the coverage fixture SHALL print the uncovered paths, so a new
  download site that forgets to record is named, not silently tolerated.

#### Scenario: A corrupt manifest is not a data-loss event
- **WHEN** the manifest fails to parse
- **THEN** downloads SHALL continue and SHALL rewrite the manifest from the
  entries they can prove (the current download), keeping the unparseable
  bytes beside it as `manifest.json.corrupt-<ts>`
- **AND** uninstall (below) SHALL treat a corrupt manifest as "manifest
  absent" and say so.

#### Scenario: Reset never edits the manifest
- **WHEN** `--reset-state` or `--reset-guest` runs
- **THEN** the manifest and every path it lists SHALL be untouched
- **AND** a reset that finds a listed path missing SHALL NOT remove the entry
  (the next download restores it).

### Requirement: `--uninstall` is the preferred removal, leaves ZERO traces, and asks before removing `~/.tillandsias/`
<!-- req-id: d0bdab27 -->

Operator ruling 2026-09-27, verbatim: "--uninstall should be the preferred
way to remove, and should leave ZERO TRACES. Prompt on uninstall if
~/.tillandsias should also be removed, [y/N], and show some clear large text
'this is the only leftover, safe to delete …'". The anchors go too. Second
ruling, same day, verbatim: "Let's wipe the unrecoverable vault store during
uninstall, together with the host keyring entry. That's what an 'UNINSTALL'
means for a user." So `~/.tillandsias/vault/` is ALWAYS removed by uninstall,
with the keyring share and root token, whatever the answer to the prompt; the
prompt and the notice cover only what stays useful without credentials:
`config/`, `downloads/` (with the manifest), `cache/`, `state/`.

`tillandsias --uninstall` (Linux headless binary), `tillandsias-tray
--uninstall` (macOS) and `tillandsias-tray.exe --uninstall` (Windows) SHALL
exist and SHALL be the preferred and documented way to remove Tillandsias;
`scripts/uninstall.sh` and `install-windows.ps1 -Uninstall/-Purge` SHALL
delegate to it when the binary is present and fall back to their own path
list only when it is not, printing that they did. Uninstall SHALL:

1. print, before deleting, every path and registration it will remove — the
   derived set, the HARD-reset set on a guest regime, the installed binary
   and its launcher registrations (desktop file, LaunchAgent, Start Menu
   shortcut, autostart entries, PATH blocks, registry Uninstall key,
   NotifyIcon settings, event-log source), every keyring entry under service
   `tillandsias` INCLUDING the install anchor (`installation-uuid-v1` /
   `tillandsias-vm-uuid`), the Tillandsias-owned block of every merged system
   file (`%USERPROFILE%\.wslconfig`, a legacy-edited `~/.config/containers/containers.conf`),
   the Linux service-account stack (`/etc/systemd/user/tillandsias.service`,
   sysusers, tmpfiles, the `tillandsias` user and `/var/lib/tillandsias`)
   when installed with privileges, and every legacy root the migration
   knows, if any still exists;
2. stop the running tray or headless process and every `tillandsias-*`
   container first;
3. remove everything in (1) PLUS `~/.tillandsias/vault/` (the store and the
   audit log; on a guest regime the guest-resident store went with the HARD
   set) — this is the ZERO-TRACES set, and it is removed unconditionally,
   before any question is asked; a merged system file is reverted, never
   deleted. The listing in (1) SHALL name the Vault store and the keyring
   entries so the operator sees, before the deletion, that the credentials
   are going;
4. then ask ONE question about what is left of `~/.tillandsias/`:
   `Also remove ~/.tillandsias (downloaded models, Tillandsias configs and caches)? [y/N]`
   — default N. Non-interactive (no TTY): N without waiting. `--remove-home`
   answers y without asking; `--keep-home` answers N without asking. On y,
   remove the whole root (on a guest regime `vm/` is already gone with the
   HARD set);
5. on N, print the large notice, verbatim shape:
   ```
   ==========================================================================
     THIS IS THE ONLY LEFTOVER — SAFE TO DELETE
     ~/.tillandsias   (<size>, <n> files)
     It holds your downloaded models, Tillandsias configs and caches —
     no credentials: the Vault store and its key were removed with the
     uninstall. Nothing else of Tillandsias remains on this machine.
     Delete it with:  rm -rf ~/.tillandsias
   ==========================================================================
   ```
   sized to the terminal, and a one-line form when there is no TTY. The
   notice MUST NOT say or imply that the kept folder holds recoverable
   credentials;
6. report what was removed and confirm that project working trees were not
   touched.

`--wipe` on `scripts/uninstall.sh` is accepted as an alias of `--remove-home`;
`TILLANDSIAS_RESET_KEEP_MODELS` is ignored by uninstall. The
`uninstall-keeps-models`, `uninstall-preserves-vm-image` and
`reset-keeps-models-macos` litmus tests and their fixtures encode the
superseded contract and SHALL be retired in the change that lands this
requirement, each with a one-line note citing 2026-09-27.

@trace spec:host-state-lifecycle, spec:environment-runtime, spec:tillandsias-vault

#### Scenario: Uninstall with N leaves exactly one folder, and it holds no credentials
- **WHEN** `tillandsias --uninstall` runs on a host with a Vault store,
  downloaded models, a manifest with N entries, and the operator answers N
  (or there is no TTY)
- **THEN** the binary, every launcher registration, every keyring entry under
  service `tillandsias` (share, root token, anchor), every `tillandsias-*`
  podman object, the Tillandsias block of every merged file and the
  service-account stack SHALL be gone
- **AND** `~/.tillandsias/vault/` SHALL NOT exist
- **AND** `~/.tillandsias/` SHALL be the only Tillandsias path left on the
  host, with `config/`, `downloads/`, `cache/` and `state/` byte-identical
- **AND** the large notice SHALL have been printed and SHALL NOT mention
  recoverable credentials.
- Pre-fix result: FAILS — no `--uninstall` flag exists on any binary;
  `scripts/uninstall.sh` never touches keyring entries or podman objects and
  `-Purge` leaves the `.wslconfig` keys.

#### Scenario: The Vault store goes whatever the answer
- **WHEN** uninstall runs and the operator answers N, y, or nothing (no TTY)
- **THEN** in every case `~/.tillandsias/vault/` and the keyring share and
  root token SHALL be gone before the prompt is even shown
- **AND** the pre-deletion listing SHALL have named them
- **AND** a fixture arm per answer SHALL assert it (three arms, same
  outcome for the store).
- Pre-fix result: FAILS — nothing removes the store or the keyring entries.

#### Scenario: Uninstall with y removes the folder too
- **WHEN** the operator answers y, or passes `--remove-home`
- **THEN** `~/.tillandsias/` SHALL NOT exist afterwards
- **AND** none of the N manifest paths SHALL exist
- **AND** no notice about a leftover SHALL be printed.
- Pre-fix result: FAILS.

#### Scenario: Non-interactive defaults to keeping the useful folder
- **WHEN** uninstall runs with stdin not a TTY and neither `--remove-home`
  nor `--keep-home`
- **THEN** it SHALL NOT block on the prompt, SHALL keep
  `~/.tillandsias/{config,downloads,cache,state}`, SHALL still have removed
  `vault/`, and SHALL print the one-line form of the notice.
- Pre-fix result: FAILS.

#### Scenario: Uninstall without a manifest still removes the known roots
- **WHEN** the manifest is absent or corrupt and the operator answers y
- **THEN** uninstall SHALL still remove the whole `~/.tillandsias/`
- **AND** SHALL print `uninstall: manifest absent — removed known roots only`
  so an unlisted download outside the root is a visible gap, not a silent
  leftover.

#### Scenario: Uninstall reverts a merged system file instead of deleting it
- **WHEN** `%USERPROFILE%\.wslconfig` contains the Tillandsias-owned block and
  keys the user wrote themselves
- **THEN** uninstall SHALL remove only the lines inside the Tillandsias-owned
  block markers
- **AND** the user's own keys SHALL be byte-identical afterwards
- **AND** the file SHALL NOT be deleted even when the block was its only
  content.
- Pre-fix result: FAILS — `-Purge` leaves the swap keys it added in place.

#### Scenario: Project working trees are never in scope
- **WHEN** uninstall runs on a host with projects registered in Tillandsias
- **THEN** no path under any project's working tree SHALL be removed or
  listed for removal (a project's own `<project>/.tillandsias/config.toml` is
  the project's, not ours)
- **AND** the final report SHALL state this (positive control from
  `environment-runtime`).

## Litmus Tests

Bind to tests in `openspec/litmus-bindings.yaml` as the packets under
1437-8c6p and 1438-pk9j land them:
- `litmus:reset-state-contract` — extended: the three reset bodies name the
  preserved operator-data set, print SOFT or HARD, and call no credential
  clearer.
- `litmus:reset-keeps-vault-store` — Linux live arm: reset, fresh Vault,
  pre-reset secret readable (destructive; smoke hosts only), plus the
  no-unlocking-keyring negative arm.
- `litmus:tillandsias-home-layout` — fresh layout, legacy migration,
  `TILLANDSIAS_HOME` seam.
- `litmus:download-manifest-coverage` — every large file under `downloads/`
  is covered by an entry; none outside it.
- `litmus:uninstall-removes-everything` — after uninstall with N exactly one
  folder remains and its `vault/` is gone; with y nothing; the store and the
  keyring entries go under every answer; merged files reverted; project
  trees untouched.

## Observability

Annotations referencing this spec can be found by:
```bash
grep -rn "@trace spec:host-state-lifecycle" crates/ scripts/ images/ --include="*.rs" --include="*.sh" --include="*.ps1"
```

## Sources of Truth

- `plan/issues/fleet-restart-2026-09-12.md` — the 2026-09-13 "reset is the
  baseline" ruling (900-z3kv).
- `plan/issues/operator-directives-reset-survivors-and-harness-bypass-2026-09-27.md`
  — the 2026-09-27 directives, the code-path audit behind this spec, and the
  same-day rulings on its open questions.
- `crates/tillandsias-core/src/reset_state.rs` — `destructive_reset_allowed`,
  `announce_reset_plan`, the shared reset wording.
