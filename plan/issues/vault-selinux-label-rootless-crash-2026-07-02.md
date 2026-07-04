# P0: vault SELinux label crashes rootless native Linux (`--init` exit 126) — 2026-07-02

- class: bug (P0 release regression)
- filed: 2026-07-02
- owner: linux
- status: done
- trace: plan/issues/selinux-vault-container-policy-phase3d-2026-06-30.md, spec:tillandsias-vault
- affected release: v0.3.260702.2 (operator-tested on Fedora Silverblue)

## Symptom

`tillandsias --init --debug` on a Fedora Silverblue host fails at vault launch:

```
[tillandsias-vault] could not stage /run/vault_container.cil for semodule: Permission denied (os error 13) (continuing)
[tillandsias-vault] launching container tillandsias-vault (alias vault:8200, publish 127.0.0.1:8201:8200)
Error: OCI runtime error: crun: `/proc/self/attr/keycreate`: OCI runtime error: unable to process security attribute
Error bringing Vault up: podman run vault failed: exit status: 126
```

## Root cause

Phase 3d (my 2026-07-01 change) assumed the vault container always launches
inside the guest VM where `tillandsias-headless` runs as **root** and can
`semodule -i` the `vault_container_t` policy. That assumption is false on the
**native rootless Linux host** (Fedora Silverblue), where vault runs directly via
rootless podman and headless is NOT root:

1. `ensure_vault_selinux_module` tried to stage the CIL to `/run/vault_container.cil`
   — not user-writable rootless → `os error 13` → returned early (failed open).
2. `semodule -i` needs root anyway → the type is never loaded.
3. The launch then STILL passed the unconditional `--security-opt
   label=type:vault_container_t`. On an enforcing host an **undefined** type makes
   crun's write to `/proc/self/attr/keycreate` fail with EINVAL → container exits
   126. (This happens on Enforcing AND Permissive — the type must be *defined*.)

Every other tillandsias container started fine because they use the default
`container_t`; only vault forced the custom, unloaded type.

## Fix

`vault_selinux_label_opt(debug) -> Option<String>` decides the label at launch:

- SELinux Disabled/absent → `None` (default; label is a no-op anyway).
- Enforcing/Permissive → use `label=type:vault_container_t` ONLY if
  `vault_container_type_loaded()` confirms it (via `semodule -l`), or if
  `try_load_vault_selinux_module` (root, guest VM) loads it. Otherwise → `None`.
- `None` ⇒ the launch omits the `--security-opt label=...` arg ⇒ podman applies
  the default **container_t** — enforcing-safe, confined, and exactly how the
  other 9 tillandsias containers already run on Silverblue.
- The CIL is now staged to `std::env::temp_dir()` (writable), not `/run`.

Net behavior:
- Guest VM (root): still loads + uses the confined `vault_container_t` (no regression).
- Rootless native host: falls back to `container_t` — no crash, still confined
  (strictly better than the pre-Phase-3c `label=disable`).

Regression guard: `vault_launch_selinux_label_is_conditional_not_unconditional`
asserts the launch derives the label from `vault_selinux_label_opt` and does NOT
hard-code the bare `label=type:vault_container_t`.

## Verifiable closure

- `./build.sh --check` + vault unit tests green; the regression litmus fails if a
  bare label is reintroduced.
- Requires a NEW release; v0.3.260702.2 is broken for the native Silverblue
  install path (the primary distribution target) and should be superseded.
