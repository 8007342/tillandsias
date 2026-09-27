<!-- @trace spec:host-state-lifecycle -->
# host-state-lifecycle Specification

## Status

active

Filed 2026-09-27 (order 1437-8c6p) from the operator's directives of the same
day. No spec owned `--reset-state`, `--reset-guest`,
`TILLANDSIAS_DESTRUCTIVE_RESET_OK`, the download cache as a unit, or an
uninstall that removes everything; `environment-runtime` owns the ACCOUNTABILITY
of the uninstall script (print before delete, report after) and keeps it.

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
containers, images, named volumes, networks, podman secrets, the guest rootfs
or WSL distro, provision markers, `init-build-state.json`, `cache_version`.
Reset destroys ALL of it, unconditionally, and rebuilds it — that is the
baseline, and it stays preferred to repair. **Operator data** is what the
operator paid for with a sign-in or a download: the Vault store and its unseal
material, the download cache (models, rootfs tarballs, toolchains, prebuilt
tools), and Tillandsias-owned configuration files. Reset never touches
operator data; only `--uninstall` does. The 2026-09-27 directive therefore
SUPERSEDES the choice recorded under 900-z3kv (option (a): "the documented
reset clears the host-held share") for the credential subject ONLY; the
idempotency principle behind 900-z3kv is unchanged and this spec restates it
for derived state.

Cross-references:
- `tillandsias-vault` — where the store and the unseal material live per
  platform, and the fresh-Vault-reads-old-store scenarios.
- `cache-recovery-mechanism` — the cache root's XDG resolution; the manifest
  lives in that root.
- `inference-container` — the model cache is operator data.
- `environment-runtime` — accountable uninstall (print, delete, report).
- `podman-idiomatic-patterns`, `wsl-runtime` — Tillandsias-owned configs.

## Requirements

### Requirement: Destructive reset destroys derived state and preserves operator data
<!-- req-id: df90fe0e -->

`--reset-state` and `--reset-guest` on every platform SHALL destroy every item
of derived state and SHALL NOT remove, move or rewrite any item of operator
data. The reset SHALL remain the preferred remedy for a broken substrate:
the code path MUST NOT grow a "repair instead of reset" branch to protect
operator data, because operator data is not inside the thing being reset.

The derived set, by platform:

- Linux: every `tillandsias-*` container, named volume, secret and network;
  `podman system reset --force` where the platform reset already uses it;
  `<cache>/init-build-state.json`, `<cache>/cache_version`, provision markers.
- macOS: `rootfs.img`, `rootfs.qcow2`, `vmlinuz`, `initramfs.img`,
  `cidata.iso`, `vm-swap.img`, `console.log`, `provision/`, `heartbeat.state`,
  `crashloop.state` under `~/Library/Application Support/tillandsias`.
- Windows: the `tillandsias` WSL distro (`wsl --unregister`), the
  `.import-complete` marker, crash-loop state.

The operator-data set, by platform (the paths are the ones the code resolves
today; a packet that moves one MUST update this list in the same change):

- Linux: `<cache>/vault-data`, `<cache>/vault-audit`, `<cache>/models`,
  `<cache>/packages`, `<cache>/forge-projects`, the download manifest and
  every path it lists; keyring entries `vault-shamir-share-v1`,
  `vault-root-token-v1` and `installation-uuid-v1` under service
  `tillandsias`; `~/.config/tillandsias`, `~/.local/share/tillandsias/nix-store`
  and `nix-cache`. `<cache>` is `$XDG_CACHE_HOME/tillandsias` or
  `~/.cache/tillandsias`.
- macOS: `~/Library/Caches/tillandsias` (models and every other download),
  the Vault store at its host-persistent location (see `tillandsias-vault`),
  Keychain items `tillandsias-vm-uuid`, `vault-shamir-share-v1`,
  `vault-root-token-v1` under service `tillandsias`.
- Windows: `%LOCALAPPDATA%\tillandsias\cache` (rootfs tarballs, the headless
  binary, models once they live outside the distro), the Vault store at its
  host-persistent location, Credential Manager targets `tillandsias-vm-uuid`,
  `vault-shamir-share-v1`, `vault-root-token-v1`, and the Tillandsias-owned
  block of `%USERPROFILE%\.wslconfig`.

`TILLANDSIAS_DESTRUCTIVE_RESET_OK=0` remains the ONE opt-out and keeps its
meaning: the reset is skipped and init runs. No new environment variable
SHALL be added to make the reset preserve operator data, because preserving
it is now the only behaviour. `TILLANDSIAS_RESET_KEEP_MODELS` becomes a no-op
that is accepted and ignored with one stderr line naming this spec, so
existing installer invocations keep working.

@trace spec:host-state-lifecycle, spec:tillandsias-vault, spec:inference-container

#### Scenario: Linux reset-state keeps the Vault store and the unseal share
- **WHEN** `tillandsias --reset-state` runs on Linux with Vault holding
  `secret/github/token` and `secret/claude/oauth`
- **THEN** `podman system reset --force` SHALL run and every image, container,
  volume, secret and network SHALL be gone
- **AND** `<cache>/vault-data` SHALL still exist with the same content digest
  as before the reset
- **AND** the keyring entry `vault-shamir-share-v1` SHALL still be present
- **AND** the following `--init` SHALL start a freshly built Vault container
  over that store, unseal it with that share, and `vault-cli read
  secret/github/token` from the git service SHALL return the pre-reset token
- **AND** no harness and no GitHub login prompt SHALL appear on the next forge
  launch.
- Pre-fix result: FAILS — `run_reset_state` calls
  `clear_host_vault_credentials`, which deletes the share, the root token and
  `<cache>/vault-data`; the next launch prompts for Claude and GitHub sign-in
  (operator observation 2026-09-27, the incident behind this spec).

#### Scenario: Linux reset-guest keeps the Vault store
- **WHEN** `tillandsias --reset-guest` runs on Linux
- **THEN** `reset_guest_wipe_paths` SHALL return no path under operator data
- **AND** `<cache>/vault-data` and `<cache>/models` SHALL be untouched.
- Pre-fix result: FAILS — `reset_guest_wipe_paths` returns
  `[<cache>/vault-data]`.

#### Scenario: Reset announces the two sets
- **WHEN** any platform reset runs
- **THEN** `announce_reset_plan` SHALL print, before destroying anything, the
  derived set it will destroy and the operator-data set it will preserve,
  naming the Vault store, the download cache and the keyring entries
  explicitly
- **AND** the preserved list SHALL be the same list this requirement names.

#### Scenario: macOS reset preserves downloads and the Vault store
- **WHEN** `tillandsias-tray --reset-state` runs on macOS
- **THEN** `~/Library/Caches/tillandsias` SHALL NOT be removed, with or without
  `TILLANDSIAS_RESET_KEEP_MODELS`
- **AND** the Vault store SHALL be readable by the reprovisioned guest's
  freshly created Vault (see `tillandsias-vault`)
- **AND** Keychain items `vault-shamir-share-v1` and `vault-root-token-v1`
  SHALL still be present.
- Pre-fix result: FAILS — `run_reset_state` removes the whole caches
  directory unless the keep-models variable is set, clears both Keychain items,
  and the store dies with `rootfs.img`.

#### Scenario: Windows reset preserves downloads and the Vault store
- **WHEN** `tillandsias-tray.exe --reset-state` runs on Windows
- **THEN** `%LOCALAPPDATA%\tillandsias\cache` SHALL NOT be removed
- **AND** the Vault store SHALL be readable by the reprovisioned distro's
  freshly created Vault
- **AND** Credential Manager targets `vault-shamir-share-v1` and
  `vault-root-token-v1` SHALL still be present.
- Pre-fix result: FAILS — `reset_state_once` removes the `cache` directory,
  calls `clear_guest_vault_credentials`, and the store dies with the distro.

#### Scenario: The opt-out still opts out of everything
- **WHEN** `TILLANDSIAS_DESTRUCTIVE_RESET_OK=0` is set and `--reset-state` runs
- **THEN** nothing in either set SHALL be removed
- **AND** the run SHALL print `RESET_SKIPPED_LINE` and proceed to init
- **AND** this behaviour is unchanged from today (positive control).

#### Scenario: A store without its share is still rebuilt, loudly
- **WHEN** `<cache>/vault-data` exists but no 32-byte Shamir share is in the
  keyring or the fallback file
- **THEN** the partial-init guard in `launch_vault_container` MAY still remove
  the store and initialise a fresh one, because an unreadable store preserves
  nothing
- **AND** it SHALL print one line naming the store path, the missing share
  name, and that every credential in the store is lost
- **AND** the reset itself SHALL NOT be the thing that removed the share.

### Requirement: Every download is recorded in one manifest under the cache root
<!-- req-id: c766b106 -->

Every artefact Tillandsias fetches from the network onto the host — rootfs
tarballs and qcow2 images, the headless binary staged for a guest, runtime
asset bundles, prebuilt forge tools, the host Chromium, nix store paths, and
the model directory — SHALL be recorded in ONE manifest file,
`<cache>/downloads.manifest.json`, through ONE recording function in
`tillandsias-core`. Each entry SHALL carry the absolute path (a file or a
directory root), the kind, the source URL or producer name, the recorded
size or digest when known, and the recording timestamp. Entries whose
contents are produced inside a container onto a bind mount (the model
directory, the package cache) SHALL be recorded once as a directory root by
the host code that creates the mount. The manifest SHALL be append-mostly:
a re-download of the same path replaces its entry; nothing else edits it.

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
- **WHEN** a hermetic `--init` completes under a fresh `HOME`
- **THEN** every regular file under `<cache>` larger than 1 MiB SHALL be
  covered by a manifest entry (itself, or a directory-root entry that is its
  ancestor)
- **AND** the coverage fixture SHALL print the uncovered paths, so a new
  download site that forgets to record is named, not silently tolerated.

#### Scenario: A corrupt manifest is not a data-loss event
- **WHEN** the manifest fails to parse
- **THEN** downloads SHALL continue and SHALL rewrite the manifest from the
  entries they can prove (the current download), keeping the unparseable
  bytes beside it as `downloads.manifest.json.corrupt-<ts>`
- **AND** uninstall (below) SHALL treat a corrupt manifest as "manifest
  absent" and say so.

#### Scenario: Reset never edits the manifest
- **WHEN** `--reset-state` or `--reset-guest` runs
- **THEN** the manifest and every path it lists SHALL be untouched
- **AND** a reset that finds a listed path missing SHALL NOT remove the entry
  (the next download restores it).

### Requirement: Manual uninstall removes everything, manifest-driven
<!-- req-id: d0bdab27 -->

`tillandsias --uninstall` (Linux headless binary), `tillandsias-tray
--uninstall` (macOS) and `tillandsias-tray.exe --uninstall` (Windows) SHALL
exist and SHALL be the only path that removes operator data. Uninstall SHALL:

1. print, before deleting, every path it will remove — the derived set, every
   manifest entry, every operator-data root named in this spec, the keyring
   or keychain or Credential Manager entries, and the installed binary and its
   launcher registrations (this is `environment-runtime`'s accountable
   uninstall, unchanged);
2. stop the running tray or headless process and every `tillandsias-*`
   container first;
3. remove the derived set (the platform reset's destroy step, without the
   reprovision);
4. remove every manifest entry that exists, then the manifest itself;
5. remove the Vault store, the audit log, the model directory and every other
   operator-data root, and delete the keyring entries INCLUDING
   `installation-uuid-v1` / `tillandsias-vm-uuid`;
6. revert, never delete, any system file Tillandsias merged into
   (`%USERPROFILE%\.wslconfig`, a user's `containers.conf` where a legacy
   install edited it): only the Tillandsias-owned block is removed;
7. report what was removed and confirm that project working trees were not
   touched.

`scripts/uninstall.sh` and `install-windows.ps1 -Uninstall/-Purge` SHALL
delegate to the binary's `--uninstall` when the binary is present and SHALL
fall back to their own path list only when it is not, printing that they did.
`--wipe` on `scripts/uninstall.sh` becomes the default and is accepted as a
no-op; `TILLANDSIAS_RESET_KEEP_MODELS` is ignored by uninstall. The
`uninstall-keeps-models` and `reset-keeps-models-macos` litmus tests and their
fixtures encode the superseded contract and SHALL be retired in the change
that lands this requirement, each with a one-line note citing 2026-09-27.

@trace spec:host-state-lifecycle, spec:environment-runtime, spec:tillandsias-vault

#### Scenario: After uninstall nothing listed remains
- **WHEN** `tillandsias --uninstall` completes on a host that had a Vault
  store, downloaded models and a manifest with N entries
- **THEN** none of the N paths SHALL exist
- **AND** `<cache>/vault-data`, `<cache>/models` and the manifest SHALL NOT
  exist
- **AND** no keyring entry under service `tillandsias` SHALL remain
- **AND** the installed binary and its launcher registration SHALL be gone.
- Pre-fix result: FAILS — no `--uninstall` flag exists on any binary;
  `scripts/uninstall.sh` keeps the cache unless `--wipe`, keeps models under
  `TILLANDSIAS_RESET_KEEP_MODELS`, and never touches keyring entries, podman
  containers, volumes, secrets or networks.

#### Scenario: Uninstall without a manifest still removes the known roots
- **WHEN** the manifest is absent or corrupt
- **THEN** uninstall SHALL still remove every operator-data root and derived
  item this spec names
- **AND** SHALL print `uninstall: manifest absent — removed known roots only`
  so an unlisted download is a visible gap, not a silent leftover.

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
  listed for removal
- **AND** the final report SHALL state this (positive control from
  `environment-runtime`).

## Litmus Tests

Bind to tests in `openspec/litmus-bindings.yaml` as the packets under
1437-8c6p land them:
- `litmus:reset-state-contract` — extended: the three reset bodies name the
  preserved operator-data set and call no credential clearer.
- `litmus:reset-keeps-vault-store` — Linux live arm: reset, fresh Vault,
  pre-reset secret readable (destructive; smoke hosts only).
- `litmus:download-manifest-coverage` — every large file under the cache root
  is covered by an entry.
- `litmus:uninstall-removes-everything` — after uninstall, no manifest path,
  no store, no keyring entry remains; project trees untouched.

## Observability

Annotations referencing this spec can be found by:
```bash
grep -rn "@trace spec:host-state-lifecycle" crates/ scripts/ images/ --include="*.rs" --include="*.sh" --include="*.ps1"
```

## Sources of Truth

- `plan/issues/fleet-restart-2026-09-12.md` — the 2026-09-13 "reset is the
  baseline" ruling (900-z3kv).
- `plan/issues/operator-directives-reset-survivors-and-harness-bypass-2026-09-27.md`
  — the 2026-09-27 directives and the code-path audit behind this spec.
- `crates/tillandsias-core/src/reset_state.rs` — `destructive_reset_allowed`,
  `announce_reset_plan`, the shared reset wording.
