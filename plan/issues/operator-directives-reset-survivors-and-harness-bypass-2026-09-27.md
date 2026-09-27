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

## Open questions for the operator

1. On a host with no usable keyring, the share lives in
   `<cache>/fallback_vault-shamir-share-v1` beside the store it unlocks. Keep
   that file across resets (the store is useless without it) or accept that
   keyring-less hosts lose credentials on reset (1118-fqfk's tmpfs intent)?
   The specs preserve it until answered.
2. macOS and Windows: host share into the guest (virtiofs / 9p, like the
   macOS model cache) or evacuate-before-wipe and rehydrate-after-provision?
   Vault's file backend over a network filesystem is untested here; the
   platform packets choose and measure, but a preference now saves a round.
3. "likely just contained in our .tillandsias downloads, configs, and caches
   folder": consolidate the XDG-spread roots (`~/.cache/tillandsias`,
   `~/.local/share/tillandsias`, `~/.config/tillandsias`,
   `~/.local/state/tillandsias`) into one `~/.tillandsias`? The manifest and
   uninstall work either way; consolidation is a separate migration packet if
   wanted.
4. Uninstall keeps nothing: also `installation-uuid-v1` / `tillandsias-vm-uuid`
   (the install anchor) and the service account's `/var/lib/tillandsias` on a
   headless install? The specs say yes to both.
5. Which consent record does the installed Claude Code actually honour for the
   bypass dialog — `bypassPermissionsModeAccepted` in `~/.claude.json` or
   `skipDangerousModePermissionPrompt` in `~/.claude/settings.json`? The seed
   writes both; the fixture records the measured answer.
