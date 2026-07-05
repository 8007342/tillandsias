# P0: vault container exits immediately + host can't resolve `vault` (rootless Silverblue) — 2026-07-03

- class: bug (P0, native rootless Linux install)
- filed: 2026-07-03
- owner: linux
- status: done
- affected release: v0.3.260703.1 (operator-tested on Fedora Silverblue)
- trace: spec:tillandsias-vault, plan/issues/vault-selinux-label-rootless-crash-2026-07-02.md

## Symptoms (two, in sequence)

After the v0.3.260703.1 SELinux fix let the vault container launch on rootless
Silverblue, `tillandsias --init` still failed — two distinct native-host bugs:

1. **Container exits immediately after launch:**
   ```
   [tillandsias-vault] ... using podman default container_t SELinux label
   [tillandsias-vault] launching container tillandsias-vault (...)
   [tillandsias] podman health failed: status=125 stderr=Error: no container with ID ... found in database: no such container
   Error bringing Vault up: vault container did not report healthy
   ```
   `podman run -d` succeeded, but vault crashed on boot and `--rm` deleted the
   container before `podman wait --condition=healthy` could see it → opaque
   "no such container".

2. **Host cannot resolve the vault service name** (earlier attempt):
   ```
   vault API probe failed: ... (https://vault:8200/v1/sys/health...): dns error:
   failed to lookup address information: Name does not resolve; retrying (N/8)
   ```

## Root causes

### (1) container_t denies the vault data volume
The v0.3.260703.1 fix fell back to podman's **default `container_t`** when the
custom `vault_container_t` type can't be loaded (rootless). But the persistent
vault data volume was created under an earlier `label=disable` regime, so its
files carry an unconfined SELinux label. Under `container_t` the vault process is
DENIED access to `/vault/data` and exits immediately. Notably,
`spec:podman-container-spec` lists `--security-opt=label=disable` as a STANDARD
tillandsias container hardening default (proxy/forge/browser all use it) — so
`container_t` was the deviation, not the norm.

### (2) `vault:8200` is enclave-only DNS
`vault_api_base_url()` returned `https://vault:8200` for ALL Linux binaries,
assuming the in-VM headless context. On a native rootless HOST, `vault` resolves
only inside the podman network's netns (aardvark-dns), and the `/etc/hosts`
fallback needs root (skipped rootless). The host must use the PUBLISHED loopback
`https://127.0.0.1:8201` (the cert already carries `IP:127.0.0.1` as a SAN).

## Fixes

- **SELinux fallback → `label=disable`** (not `container_t`) on the rootless host
  in `vault_selinux_label_opt`. Restores the pre-Phase-3c behavior that worked on
  Silverblue and matches the project's standard container hardening default. The
  confined `vault_container_t` path still applies inside the guest VM (root).
- **Host base URL → loopback** in `vault_api_base_url`: native host (`!is_running_in_vm()`)
  uses `https://127.0.0.1:8201`; in-VM headless keeps `https://vault:8200`.
- **Diagnosability**: removed `--rm` from the vault launch (a crashed container
  now persists; the next launch's `podman rm -f` cleans up) and added
  `dump_vault_failure_diagnostics()` — on a failed health wait it prints the
  container state + last 40 log lines, so a boot crash is never opaque again.

## Follow-up (hardening, not blocking)

Restore host-side SELinux confinement for the vault container without root:
either relabel the data volume for `container_t` (`:Z` mount) so the default
type works, or ship a privileged one-shot policy-load helper. Tracked separately.

## Verifiable closure

- `./build.sh --check` + vault unit tests green.
- Needs a new release (v0.3.260703.2) for operator re-test on Silverblue; if the
  container still exits, the new `podman logs` dump will show the exact cause.
