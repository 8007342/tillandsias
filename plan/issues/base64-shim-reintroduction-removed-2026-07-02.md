# base64 podman shim reintroduced on windows-next — removed + now enforced — 2026-07-02

- class: enhancement (methodology enforcement)
- filed: 2026-07-02
- owner: linux
- status: done
- trace: methodology.yaml base64_script_injection_ban, plan/issues/violation-python-base64-injection-2026-07-01.md

## What happened

During the 2026-07-02 windows-next → linux-next integration merge, the merged
`crates/tillandsias-host-shell/src/pty/mod.rs` was found to contain
`PODMAN_SELINUX_WRAP_B64` — a **base64-encoded bash podman wrapper** that
`vm_login_shell_argv` decoded at runtime (`base64 -d > /tmp/podman-selinux-wrap
&& chmod +x ... && export TILLANDSIAS_PODMAN_BIN=...`) to swap
`label=type:vault_container_t` → `label=disable` for the vault container.

This came from windows-next commit `0c4a6aa3` ("replace python3 podman wrapper
with bash one-liner"). It is exactly the pattern the `base64_script_injection_ban`
CRITICAL_VIOLATION forbids — the 2026-07-01 incident report explicitly noted that
replacing the Python b64 with a bash b64 is "continuing the same deceptive
mechanism in a different language."

## Why it was also redundant

Phase 3d already fixed the underlying SELinux problem the shim worked around:
`vault_bootstrap::ensure_vault_selinux_module` loads
`images/selinux/vault_container.cil` (permissive `vault_container_t`) in-guest
BEFORE the vault launch, so `label=type:vault_container_t` is a valid label and
crun no longer EINVALs. The host-side podman wrapper is unnecessary on every
guest (WSL: SELinux Disabled → label is a no-op; macOS VZ / native: Phase 3d
loads the type).

## Resolution

- Removed `PODMAN_SELINUX_WRAP_B64` and the shim install from
  `vm_login_shell_argv`; the login preamble now just sets HOME / XDG_RUNTIME_DIR
  / TILLANDSIAS_VAULT_API_BASE_URL and execs the tail. All three intents
  (GithubLogin / Agent / cloud) use it.
- Updated the `launch_spec` unit tests to ASSERT the login script contains no
  `podman-selinux-wrap` shim (guards the specific reintroduction site).
- Added `scripts/check-no-base64-script-injection.sh`: a verifiable repo-wide
  checker that fails on the decode-to-executable idiom (`base64 -d`/`--decode`
  co-located with `chmod +x` / `TILLANDSIAS_PODMAN_BIN`). Narrow by design so
  legitimate base64 DATA decodes (Vault Shamir key in `images/vault/entrypoint.sh`,
  archived cheatsheet examples) do not trip. Referenced from
  methodology.yaml `base64_script_injection_ban.checker`.

## Verifiable closure

- `scripts/check-no-base64-script-injection.sh` exits 0 on the current tree and
  exits 1 on a reintroduced decode-to-executable idiom (both verified).
- `tillandsias-host-shell` launch_spec tests assert no shim; `./build.sh --check`
  and `--test` pass.

## Follow-up (filed as order 169)

Neither `check-no-python-scripts.sh` nor this new checker is wired into
`./build.sh --ci-full` yet — both are declared `checker:`s in methodology but
run only on demand. Wire both policy checkers into the CI gate so the bans fail
the build automatically, not just when someone runs them.
