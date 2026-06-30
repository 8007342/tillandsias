# Build-Install-Smoke E2E Findings — 2026-06-25

**Run ID**: 20260626T062219Z  
**Commit tested**: a6abaf83 (osx-next HEAD)  
**Installed version**: Tillandsias v0.3.260625.1  
**Host**: macos (arm64, darwin)  
**Log dir**: target/build-install-smoke-e2e/20260626T062219Z/

---

## Gate Results

| Gate | Result | Notes |
|------|--------|-------|
| §0 Preflight | PASS | branch=osx-next, arm64, build script present |
| §1 Build + install | PASS | codesign verified, freshness gate matched HEAD |
| §2 Destroy VM state | PASS | 1.7G VM state wiped |
| §3 Cold provision | PASS | rootfs.img 5.0G, diagnose exit 0 (provisioned) |
| §4 Forge meta-orch | N/A | Linux-only lane |
| §5 `--github-login` | FAIL | See findings below |

**Overall**: PARTIAL (vault bootstrap fix confirmed, but 3 product issues found)

---

## Finding 1: TILLANDSIAS_VAULT_API_BASE_URL lost through vsock exec env clear

**Severity**: blocker  
**File**: `crates/tillandsias-macos-tray/src/diagnose.rs:530`

**Symptom**: `--github-login` vault health probe hits `https://127.0.0.1:8201` instead of the enclave IP `https://10.0.42.2:8200` (on macOS VZ VM). Vault podman healthcheck passes but the API-level probe times out against the wrong address.

**Root cause**: The vsock exec PTY handler (`pty_handler.rs:125`) calls `cmd.env_clear()` — the child process inherits ONLY the environment variables from the `PtyOpen` envelope (`TERM=dumb` plus a default `PATH`). The `TILLANDSIS_VAULT_API_BASE_URL` env var, which the systemd unit correctly sets via `Environment=`, is never forwarded. The `github_login_main` bash command in `diagnose.rs` exports `HOME` and `XDG_RUNTIME_DIR` but was missing `TILLANDSIAS_VAULT_API_BASE_URL`.

**Fix applied**: Added `export TILLANDSIAS_VAULT_API_BASE_URL=https://10.0.42.2:8200` to the bash command in `diagnose.rs:543`.

**Status**: fixed in commit (pending push)

---

## Finding 2: Stale vault data volume prevents re-init after failed bootstrap

**Severity**: blocker  
**File**: `crates/tillandsias-headless/src/vault_bootstrap.rs:1098`

**Symptom**: On the second `--github-login` attempt (after fixing the env var), the vault container starts but exits immediately with `curl: (22) HTTP 400` on the unseal API call. Podman logs show "subsequent boot: using unseal key from secret" + "unsealing vault" + `curl: (22) The requested URL returned error: 400`.

**Root cause**: The first attempt (with the broken env var) partially initialized the vault — `vault operator init` generated a random Shamir key, wrote it to the tmpfs handover, but the handover was never captured because `wait_for_vault_ready()` timed out against `127.0.0.1:8201`. The vault data persisted in the `tillandsias-vault-data` podman volume. On the second attempt, `ensure_unseal_key()` re-derived the HKDF key (no keychain entry from the failed capture), which didn't match the initialized vault's Shamir key. The unseal failed with HTTP 400.

The `launch_vault_container()` function removes the old container but NOT the stale data volume. The volume persists across bootstrap attempts with mismatched keys.

**Fix applied**: Added `podman volume rm -f tillandsias-vault-data` to `launch_vault_container()` before launching. Manual workaround: `podman volume rm -f tillandsias-vault-data` via `--exec-guest`.

**Note**: This fix is in `tillandsias-headless` which runs Linux-side inside the VM. The VM fetches the headless binary from GitHub releases (see `fetch-headless.sh` in cloud-init). The fix won't take effect until a new headless release is cut. For testing, we worked around it by manually cleaning the volume.

**Status**: fixed in source (pending release)

---

## Finding 3: Released headless binary has stale auth preflight requiring tillandsias-git

**Severity**: blocker  
**File**: (released binary, not in current source)

**Symptom**: After vault bootstrap succeeds, the headless prints `Error: auth preflight failed: tillandsias-git is not running (None)`. The released headless binary (fetched from GitHub releases by `fetch-headless.sh`) has a preflight check that requires the `tillandsias-git` container to be running before allowing the `--github-login` flow. The current source code's `run_github_login` no longer has this check.

**Root cause**: The released binary is out of date relative to `osx-next` HEAD. The `fetch-headless.sh` cloud-init script downloads `tillandsias-headless-aarch64-unknown-linux-musl` from the latest GitHub release. The latest release was built from a different source version that included an auth preflight check looking for `tillandsias-git`.

**Impact**: All `--github-login` attempts on macOS VZ VMs using the released headless will fail at this gate.

**Workaround**: Ensure `tillandsias-git` container is running before the github-login flow. However, `podman run -d` and `podman start` via the vsock exec PTY both hang (see Finding 5).

**Status**: requires new headless release or cloud-init user-data fix

---

## Finding 4: All hardcoded IPs need eradication (architecture debt)

**Severity**: architecture  
**Reference**: user feedback during smoke test

**Inventory completed 2026-06-26T09:27Z**:

Command: `rg -n "10\\.0\\.42\\." crates`

Production URLs / service discovery:
- `crates/tillandsias-macos-tray/src/diagnose.rs:544` — exports `TILLANDSIAS_VAULT_API_BASE_URL=https://10.0.42.2:8200` for guest `--github-login`.
- `crates/tillandsias-vm-layer/src/vz.rs:508` — systemd unit sets `TILLANDSIAS_VAULT_API_BASE_URL=https://10.0.42.2:8200`.
- `crates/tillandsias-headless/src/vault_bootstrap.rs:37` — `VAULT_ENCLAVE_IP = "10.0.42.2"` feeds the Vault `--ip`, TLS SAN, and enclave API base URL.

Network shape / proxy bypass:
- `crates/tillandsias-headless/src/main.rs:716` — `ENCLAVE_SUBNET = "10.0.42.0/24"` hardcodes the bridge subnet at network creation.
- `crates/tillandsias-headless/src/main.rs:729` — `ENCLAVE_NO_PROXY` embeds `10.0.42.0/24`.

Tests / comments:
- `crates/tillandsias-vm-layer/src/vz.rs:1682` — unit test pins the current systemd env line.
- `crates/tillandsias-headless/src/main.rs:8067` — test asserts git login args do not include `10.0.42.2`.
- `crates/tillandsias-headless/tests/cache_peer_routing.rs:194` — comment documents a wrong `cache_peer 10.0.42.x` shape.
- `crates/tillandsias-macos-tray/src/diagnose.rs:537` — comment documents why the env override targets the enclave IP today.

Coupled sequencing note: the Vault port publish cannot be removed safely as a
standalone first step because Linux's default `host_base_url()` still points to
`https://127.0.0.1:8201`. The removal slice must either happen with the DNS/base
URL migration or first introduce a Linux-safe non-published access path.

**Progress 2026-06-26T09:33Z**: completed `hardcoded-ip/subnet-constant`.
`crates/tillandsias-headless/src/main.rs` now reads
`TILLANDSIAS_ENCLAVE_SUBNET`, defaults to `10.0.42.0/24`, uses that value for
`podman network create --subnet`, and derives `NO_PROXY`/`no_proxy` for forge,
inference, stack, and tray launch paths from the same helper. Updated the
inference-container spec/litmuses to pin `enclave_no_proxy()` instead of the old
static `ENCLAVE_NO_PROXY` constant. Verification:
`cargo test -p tillandsias-headless enclave_`,
`scripts/run-litmus-test.sh inference-container --phase pre-build --size instant --compact`,
and `./build.sh --check` all passed.

**Transport probe 2026-06-26T10:00Z**: attempted the
`hardcoded-ip/remove-port-publish` follow-up and found it is blocked until the
non-published access path lands. With proxy bypass forced, direct host access to
`https://10.0.42.2:8200/v1/sys/health` timed out after 8s, and
`https://vault:8200/v1/sys/health` failed DNS resolution from the host. The plan
graph now runs `hardcoded-ip/dns-migration` before removing
`-p 127.0.0.1:8201:8200`.

**Required approach**:
- VM host processes should resolve `vault` via podman's aardvark-dns (running on bridge gateway)
- Configure systemd-resolved or resolv.conf to forward enclave DNS queries
- Remove `-p` port publish for non-diagnostic use — all host-to-enclave communication should use vsock or podman exec
- Standardize on podman `--network-alias` for service discovery across all containers

**Progress 2026-06-26T10:55Z**: completed `hardcoded-ip/dns-migration`.
Vault service identity now uses the `vault` DNS name: the Vault container no
longer passes a singleton `--ip`, the TLS leaf SAN is `DNS:vault`,
`TILLANDSIAS_VAULT_API_BASE_URL` in the macOS VM unit and control-wire login
driver is `https://vault:8200`, and rootful VM guests write a
systemd-resolved drop-in that routes the single-label `vault` name to the
Podman network gateway discovered from `podman network inspect`. Verification:
`cargo test -p tillandsias-headless enclave_`,
`cargo test -p tillandsias-headless vault_`,
`cargo test -p tillandsias-vm-layer vz_cloud_init_headless_service_has_control_wire_preflight`,
`cargo check -p tillandsias-macos-tray`, and `./build.sh --check` all passed.
Source scan `rg -n "10\.0\.42\.2|VAULT_ENCLAVE_IP|https://10\.0\.42\.2|IP:\{VAULT" crates/**/*.rs`
returned no matches. The Linux loopback publish remains intentionally in place:
native Linux still needs a non-published host access path (vsock or podman-exec)
before `hardcoded-ip/remove-port-publish` can be safely completed.

**Status**: filed as optimization work packet

---

## Finding 5: Stdio::null() patterns swallow command failure context

**Severity**: observability  
**Reference**: user feedback during smoke test

**Symptom**: Multiple locations in the Rust codebase use `Stdio::null()` for both stdout and stderr of critical podman commands. When a command fails, the failure context is lost, making post-mortem diagnosis nearly impossible. We had to resort to `--exec-guest` fishing to find failure state.

**Locations found** (not exhaustive):
- `vault_bootstrap.rs:1098-1102` — `podman rm -f` (our stale-volume fix also uses null)
- `vault_bootstrap.rs` — various cleanup calls
- `main.rs` — various `run_command_silent` calls

**Required approach**:
- Replace `Stdio::null()` with structured logging that captures exit status + stderr
- Add `--debug=module:LEVEL` support for filtered diagnostics
- Add a diagnostics ring-buffer that persists the last N command results
- Log command signatures (truncated args, not secrets) alongside exit codes

**Status**: filed as optimization work packet

---

## Finding 6: podman run/start via vsock exec PTY hangs on long-lived containers

**Severity**: infrastructure  
**Observed on**: macOS VZ VM (Fedora 44 guest)

**Symptom**: `--exec-guest podman run -d ...` and `--exec-guest podman start <container>` both time out at 120s+. Even though `-d` should detach, the PTY session never closes because podman's output stream doesn't EOF.

**Impact**: Cannot start containers in the VM via the vsock control wire. Only the headless's internal `podman_cmd_sync()` (which uses `std::process::Command` with proper wait) can start containers.

**Workaround**: Use `podman create` (succeeds) followed by the headless's internal container management. For manual testing, `podman create` + `podman start -a` doesn't work because `podman start` without `-a` doesn't exist on podman 5.8.

**Status**: filed as infrastructure work packet

---

## Re-verification Addendum: 2026-06-26 macOS recheck

The same blocker was rechecked on commit `7441cfad` with log dir
`target/build-install-smoke-e2e/20260626T153311Z/`.

- `04-github-login.log:1-4` shows the fixed ordering: VM start, control-wire
  wait, control-wire ready, then guest auth preflight before credential
  prompts.
- `04-github-login.log:5-15` shows the remaining blocker: Vault bootstrap
  succeeds, then the released headless aborts with `auth preflight failed:
  tillandsias-git is not running (Some("container not found"))`.

This is the existing order-101 packet in `plan/index.yaml`; no new issue was
filed.
