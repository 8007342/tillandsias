# SELinux vault_container_t policy — Phase 3d (load module in guest)

**Filed:** 2026-06-30 (osx-next github-login + list-cloud-projects E2E run)
**Kind:** correctness / security hardening
**Status:** done (linux-side, 2026-07-01)
**Host:** guest-side (shared: Fedora 44 guest, all platforms)
**Trace:** `spec:tillandsias-vault`, Phase 3c/3d from `dbafa9c0`

## Resolution 2026-07-01 (linux — headless-side load, unblocks macOS)

Implemented Phase 3d as a **self-contained headless step** rather than a
per-platform provision-time compile, because the vault container is launched by
`tillandsias-headless` inside every guest (macOS VZ, native Linux, WSL) — so
loading the module there fixes all three at once and lives entirely in
linux-owned scope (`crates/tillandsias-headless/`, `images/selinux/`):

- `images/selinux/vault_container.cil` — minimal CIL that DECLARES
  `vault_container_t` (base refpolicy only: `system_r`, `domain`) and marks it
  `typepermissive`. This makes `label=type:vault_container_t` a *valid* type so
  crun no longer hits EINVAL on `/proc/self/attr/keycreate`; permissive keeps
  vault operations from being denied while the confined ruleset in
  `images/selinux/tillandsias_vault.te` is matured. No `make`, no
  `selinux-policy-devel`, no `semanage`, no container-selinux attribute names —
  so `semodule -i` succeeds on a stock Fedora 44 guest.
- `vault_bootstrap.rs::ensure_vault_selinux_module(debug)` — called right before
  the labelled `podman run`. Failure-open and idempotent: no-op when
  `getenforce` is Disabled/absent; skips when `semodule -l` already lists the
  module; otherwise stages the CIL to `/run/vault_container.cil` and
  `semodule -i`. Errors never abort the launch (podman surfaces the real error).
- Litmus: `vault_launch_ensures_selinux_module_before_labelled_run` pins that
  the ensure step precedes the labelled run and that the CIL declares the type.

This supersedes the base64 Python/bash podman-wrapper stopgap (already removed on
osx-next in `dc668287`; merged to linux-next this cycle). The
`.te`→enforcing-mode hardening (drop `typepermissive`, ship the full ruleset)
remains a follow-up, tracked below.

## Background

Phase 3c (`dbafa9c0 feat(selinux): Phase 3c/3d`) replaced
`--security-opt label=disable` with `--security-opt label=type:vault_container_t`
in `vault_bootstrap.rs` for the vault container launch. The commit stated:
> On a SELinux-Disabled system (current state) the `label=` option is silently
> ignored by podman, so this is a safe non-breaking change.

That assumption was **incorrect**. The Fedora 44 guest has SELinux in **enforcing
mode** (`sestatus: Current mode: enforcing`). crun tries to write the label to
`/proc/self/attr/keycreate`; the kernel rejects it with EINVAL when
`vault_container_t` is not in the loaded policy (not a denial — an invalid type).
This caused:

```
Error: OCI runtime error: crun: `/proc/self/attr/keycreate`: OCI runtime error:
unable to process security attribute
Error: podman run vault failed: exit status: 126
```

blocking all `--github-login` and `--list-cloud-projects` runs on macOS.

## Current stopgap (1325bea9)

A Python podman wrapper is installed in the `--github-login` and
`--list-cloud-projects` preflights. It replaces
`label=type:vault_container_t` → `label=disable` for the vault container only.
Headless picks it up via `TILLANDSIAS_PODMAN_BIN=/tmp/podman-selinux-wrap`.

This is intentionally temporary — `label=disable` bypasses all MAC enforcement
on the vault process.

## What Phase 3d must do

1. **Write** `images/selinux/vault_container.te` — a minimal type enforcement file
   declaring `vault_container_t` as a domain that can act as a container
   (inheriting from `svirt_sandbox_domain` or `container_domain`).
2. **Compile** it to a `.pp` or `.cil` module. On Fedora 44 the guest has
   `checkpolicy` but not `semodule_package`; use CIL directly:
   ```
   semodule -i vault_container.cil
   ```
   Note: `semodule` rebuilds the full policy — this takes 3–5 minutes on the VZ
   guest. Plan accordingly (one-time provision step, not per-boot).
3. **Install during provision** — add the `semodule -i` call to the provisioning
   script / headless `--provision` flow so it persists in rootfs.img.
4. **Remove the stopgap** from `diagnose.rs` `github_login_main()` and
   `list_cloud_projects_main()` preflights once the module is loaded.

## Minimal CIL skeleton

```cil
; vault_container.cil — SELinux policy for Tillandsias vault container
; Declares vault_container_t as a confined container domain.
(type vault_container_t)
(roletype system_r vault_container_t)
(typeattributeset domain (vault_container_t))
(typeattributeset svirt_sandbox_domain (vault_container_t))
(allow vault_container_t self (process (fork signal sigchld)))
```

Adjust after verifying with `audit2allow` on any AVC denials from a real vault
container run under `label=type:vault_container_t` with the module loaded.

## Validation

After installing the module, remove `TILLANDSIAS_PODMAN_BIN` from the preflights
and re-run `--github-login` + `--list-cloud-projects`. Expect:
- No crun `/proc/self/attr/keycreate` error
- `[tillandsias-vault] bootstrap complete`
- `exit_code: 0` on both commands

Verify `semodule -l | grep vault` shows the module loaded.
