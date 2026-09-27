# Operator directives 2026-09-27: harness bypass pre-accepted, Vault store and download cache survive reset, manifest-driven uninstall, owned configs

Umbrella order: 1437-8c6p. Specs: `host-state-lifecycle` (new),
`tillandsias-vault`, `default-image`, `environment-runtime`,
`cache-recovery-mechanism`, `podman-idiomatic-patterns`,
`podman-registries-config`, `wsl-runtime`, `inference-container`.

## The directives (verbatim intent, 2026-09-27)

1. Skip the bypass-permissions confirmation and pre-accept it, for all
   projects, for all harnesses.
2. When we wipe all containers and images on all hosts, keep the credentials
   — the Vault store — since a newly created Vault using the unlock key still
   in the session keyring can unlock and read them. Codex, Antigravity and
   OpenCode credentials must likewise be saved transparently and survive
   Vault/container/image wipes.
3. The Vault store and the download cache survive system wipes. Only a manual
   `tillandsias --uninstall` wipes everything, including the Vault store,
   downloaded caches and ollama models.
4. A manifest in the download cache so uninstall removes everything we
   downloaded.
5. Store our `.wslconfig`, podman configs and the like under our own
   directory and always use our config over the system defaults.

## What the code does today (audit, by symbol)

- The incident the operator saw (manual Claude and GitHub sign-in after a
  forge launch although both were in Vault) is a direct consequence of two
  earlier rulings composed: `scripts/install.sh` runs `--reset-state` on every
  install (1286-4437), and `run_reset_state` calls
  `clear_host_vault_credentials` (900-z3kv), which deletes the Shamir share,
  the root token and the store directory. Every install since 2026-09-20 has
  therefore discarded every sign-in.
- The Linux Vault store is a HOST DIRECTORY bind mount, `<cache>/vault-data`,
  bound by `launch_vault_container`; `vault_data_volume_exists` checks the
  directory. The spec, `vault_bootstrap.rs` comments and one error message,
  `main.rs` and two cheatsheets still say "podman volume
  `tillandsias-vault-data`". No such volume exists (packet 1437-rzf2).
- `run_reset_guest` removes the store through `reset_guest_wipe_paths`
  (returns the store path only) and leaves the keychain alone; that is the
  worst combination, because `launch_vault_container`'s partial-init guard
  then sees no store and re-initialises, and the stale share in the keychain
  is overwritten.
- macOS: the store is inside `rootfs.img` at `/root/.cache/tillandsias/vault-data`
  (`plan/issues/macos-vault-data-guest-local-not-upgrade-persistent-2026-07-24.md`);
  `VzRuntime::wipe_provisioned_artifacts` destroys it; the tray's
  `run_reset_state` also clears both Keychain items and removes the whole
  `~/Library/Caches/tillandsias` unless `TILLANDSIAS_RESET_KEEP_MODELS=1`.
- Windows: the store is inside the `tillandsias` distro; `reset_state_once`
  unregisters the distro, calls `clear_guest_vault_credentials`, and removes
  `%LOCALAPPDATA%\tillandsias\cache` (rootfs tarballs, staged headless binary).
  Models are inside the distro too (1182-2vaz).
- `tillandsias --uninstall` does not exist on any binary. `scripts/uninstall.sh`
  keeps the cache unless `--wipe`, keeps models under the keep variable, and
  never touches keyring entries or podman objects. `install-windows.ps1 -Purge`
  leaves the `.wslconfig` keys it added.
- No download manifest exists. Closest records: `InitBuildState`
  (built images), `runtime/<ver>/manifest.json` (embedded assets), the
  models directory's `.preloaded` and `.engine-set` markers.
- Bypass consent: `entrypoint-forge-claude.sh` passes
  `--dangerously-skip-permissions`, but `seed_claude_first_run_defaults`
  seeds only onboarding and theme; the consent is remembered only via
  `claude-approvals-vault.sh` (the 2026-08-31 "prompt once, then vault it"
  directive), so a Vault wipe brings the dialog back. Codex and Antigravity
  pass their bypass flags forge-gated; OpenCode's `"permission": "allow"` in
  the config overlay is applied regardless of `TILLANDSIAS_HOST_KIND`.
- Podman config: `--init` edits the user's `~/.config/containers/containers.conf`
  in place (`ensure_pasta_options_ipv4_only`, `ensure_containers_conf_dns_servers`,
  `ensure_containers_conf_no_proxy_env`) and sets no `CONTAINERS_*` variable;
  `registries.conf` is only the developer copy from
  `scripts/setup-podman-registries.sh`. `.wslconfig` is merged by
  `Get-WslConfigMerge` with consent, without a marked block and without an
  un-merge.

## Reconciliation with "reset is the baseline" (900-z3kv)

Both rulings hold by classifying state: DERIVED state (containers, images,
volumes, secrets, networks, guest rootfs, WSL distro, provision markers,
`init-build-state.json`, `cache_version`) is destroyed and rebuilt by every
reset, unconditionally — the baseline stays preferred to repair. OPERATOR
DATA (Vault store, unseal material, download cache, models, owned configs) is
outside the reset and is removed only by uninstall. The 2026-09-27 directive
supersedes 900-z3kv's option (a) for the credential subject only. Stated in
`host-state-lifecycle` and `tillandsias-vault`.

## Existing packets whose premise changes

- 1118-fqfk (ready, p1): asked `--reset-guest` to wipe the fallback share.
  The share must now survive resets; whether the FALLBACK FILE may move to
  tmpfs on keyring-less hosts is an open operator question below. Note event
  appended.
- 1419-e2sm (ready): records the bypass dialog as a manual step on a CLI
  relaunch and wonders whether the operator wants it manual. Answered
  2026-09-27: pre-accept. Note event appended; 1437-y2wu supersedes its
  bypass half.
- 900-z3kv, 804-ckst (closed): superseded for the credential subject; left
  closed, cited in the spec.
- 1182-2vaz (ready, windows): models inside the distro; 1437-3iux folds the
  requirement and names it.
- 536 (ready): harness first-run onboarding bypass; 1437-y2wu and 1437-q9ti
  cover the consent half; the theme/trust half stays with 536.

## Packets (see the fragments under plan/index.d for 1437-*)

| order | title | platform | size | tier |
|---|---|---|---|---|
| 1437-8c6p | umbrella | any | — | — |
| 1437-qza3 | Linux reset keeps the Vault store and the share | linux | L | opus |
| 1437-av8u | macOS store and caches host-persistent across reset | macos | L | opus |
| 1437-3iux | Windows store and caches host-persistent across reset | windows | L | opus |
| 1437-y2wu | Claude forge bypass pre-accepted at launch | linux | M | sonnet |
| 1437-q9ti | Codex, Antigravity, OpenCode bypass pre-accepted and forge-gated | linux | M | sonnet |
| 1437-jdgg | download manifest in tillandsias-core plus Linux sites | linux | L | opus |
| 1437-evzi | `--uninstall` on every binary, manifest-driven | any | L | opus |
| 1437-2pix | owned podman configs, explicit on every invocation | linux | L | opus |
| 1437-6ghz | owned WSL config block and un-merge | windows | M | sonnet |
| 1437-rzf2 | retire the stale `tillandsias-vault-data` volume text | any | S | haiku |
| 1437-5hpv | OpenCode auth store in Vault | linux | M | opus |
| 1438-pk9j | `~/.tillandsias/` single root, resolver and first-launch migration (added by the 2026-09-27 rulings) | linux | L | opus |

## Operator rulings on the open questions (2026-09-27, same day; order 1438-pk9j)

1. Keyring: "the presence of an unlocking keyring should be a requirement to
   survive the vault store." No persisted fallback share file on any host; a
   host without an unlocking keyring does not keep its store across a reset
   and the reset says so first. Specs: `tillandsias-vault` "No unlocking
   keyring, no persisted share, no survival"; `host-state-lifecycle`.
   1437-qza3's criteria amended by event (lenovinha's local cut preserved the
   fallback files — reversed); 1118-fqfk confirmed and widened.
2. Guest regimes get a SOFT and a HARD reset. HARD = today's wipe of the VM
   and guest (stores and share go, announced). SOFT = "the VM and the FEDORA
   GUEST are kept, but the tillandsias binary and the Tillandsias STORES
   (Vault, Caches, Downloaded stuff, etc) is kept. We can still wipe the
   previous containers, and inject the new updated tillandsias binary, and
   let it initialize the containers in the guest from scratch, as if it were
   doing in a native linux 'reset' which preserves stores." `--reset-state`
   is SOFT everywhere; `--reset-guest` is HARD on guest regimes. Installer:
   SOFT for an update, HARD only on explicit request
   (`TILLANDSIAS_INSTALL_RESET=hard`), recommended default SOFT. The
   evacuate-vs-share question for the Vault store is dissolved (the guest is
   the persistent thing); what is left is the host-side models/downloads
   share, already present on macOS (virtiofs), measured on Windows by
   1437-3iux. 1437-av8u and 1437-3iux re-scoped by event and re-titled.
3. One folder: "keep all our configs and downloaded files in ~/.tillandsias/
   for a user to easily find them, snoop around, and wipe them afterwards."
   Layout `config/ downloads/ vault/ cache/ state/ vm/`, `TILLANDSIAS_HOME`
   seam, first-launch migration from every legacy root, convergence from any
   mixed state without prompting. New packet 1438-pk9j; 1437-jdgg (manifest
   at `downloads/manifest.json`), 1437-2pix, 1437-6ghz, 1437-rzf2 path-amended
   by event; `cache-recovery-mechanism`, `environment-runtime`,
   `inference-container` superseded their XDG / `~/Library` / `%APPDATA%`
   paths.
4. Uninstall: "--uninstall should be the preferred way to remove, and should
   leave ZERO TRACES. Prompt on uninstall if ~/.tillandsias should also be
   removed, [y/N], and show some clear large text 'this is the only leftover,
   safe to delete …'". Anchors and `/var/lib/tillandsias` go. Non-interactive
   defaults to N; `--remove-home` / `--keep-home`; the notice shape is in the
   spec. 1437-evzi re-scoped by event and re-titled. The flagged
   interpretation (a kept folder with an unlockable store) was RULED the same
   day, verbatim: "Let's wipe the unrecoverable vault store during uninstall,
   together with the host keyring entry. That's what an 'UNINSTALL' means for
   a user." So `vault/` and the keyring entries go under every answer; the
   prompt and the notice cover only `config/ downloads/ cache/ state/`, and
   the notice must not imply recoverable credentials.
5. Consent key: measured by 1437-y2wu's live arm; unchanged.
