## 1. Proxy Container Image

- [ ] 1.1 Create `images/proxy/Containerfile` — Alpine + squid, non-root user, ~15MB
- [ ] 1.2 Create `images/proxy/squid.conf` — caching proxy config, 500MB disk cache, domain ACLs
- [ ] 1.3 Create `images/proxy/allowlist.txt` — curated domain allowlist for web/mobile/cloud dev
- [ ] 1.4 Create `images/proxy/entrypoint.sh` — initialize cache dirs, start squid foreground
- [ ] 1.5 Register `proxy` image type in `build-image.sh` so `build-image.sh proxy` works
- [ ] 1.6 Test: `build-image.sh proxy --tag tillandsias-proxy:v0.1.126` builds successfully under 30MB

## 2. Enclave Network Management

- [ ] 2.1 Add `ensure_enclave_network()` to `tillandsias-podman` crate — creates `tillandsias-enclave` if absent
- [ ] 2.2 Add `remove_enclave_network()` to `tillandsias-podman` crate — removes network if no containers attached
- [ ] 2.3 Add `network_exists()` check to `tillandsias-podman` crate
- [ ] 2.4 Call `ensure_enclave_network()` before any container launch in `handlers.rs`
- [ ] 2.5 Call `remove_enclave_network()` on app exit in `main.rs`

## 3. Proxy Container Profile & Lifecycle

- [ ] 3.1 Add `proxy_profile()` to `container_profile.rs` — dual-network, cache volume, no secrets
- [ ] 3.2 Add `ProxyState` to `TrayState` — tracks proxy container running/stopped
- [ ] 3.3 Add `ensure_proxy_running()` to `handlers.rs` — start proxy if not running, health-check
- [ ] 3.4 Call `ensure_proxy_running()` before forge launch in `handle_attach_here()`
- [ ] 3.5 Call `ensure_proxy_running()` before forge launch in CLI `runner::run()`
- [ ] 3.6 Stop proxy container on app exit alongside enclave network cleanup
- [ ] 3.7 Add proxy health check to event loop (60-second interval)

## 4. Forge Network Integration

- [ ] 4.1 Modify `build_podman_args()` in `launch.rs` to add `--network=tillandsias-enclave`
- [ ] 4.2 Add `HTTP_PROXY`, `HTTPS_PROXY`, `NO_PROXY` env vars to forge profiles in `container_profile.rs`
- [ ] 4.3 Update `common_forge_env()` with proxy env vars (conditional on enclave being active)
- [ ] 4.4 Update launch.rs tests to verify enclave network attachment and proxy env vars

## 5. Accountability Windows

- [ ] 5.1 Add `ProxyManagement` and `EnclaveManagement` variants to `AccountabilityWindow` in `cli.rs`
- [ ] 5.2 Add `--log-proxy` and `--log-enclave` flag parsing in `parse_log_flags()`
- [ ] 5.3 Add proxy/enclave log targets to `logging.rs` module-to-targets mapping
- [ ] 5.4 Add `@trace spec:proxy-container` and `@trace spec:enclave-network` annotations to all new code
- [ ] 5.5 Update USAGE string in `cli.rs` with new accountability flags
- [ ] 5.6 Update `docs/cheatsheets/logging-levels.md` with new accountability windows

## 6. Documentation & Cheatsheets

- [ ] 6.1 Create `docs/cheatsheets/enclave-architecture.md` with architecture diagram and trace references
- [ ] 6.2 Update `docs/cheatsheets/secret-management.md` to reference enclave isolation
- [ ] 6.3 Add `@trace spec:enclave-network` and `@trace spec:proxy-container` to all modified source files
- [ ] 6.4 Update CLAUDE.md with enclave architecture section

## 7. Testing & Verification

- [ ] 7.1 Run `cargo test --workspace` — all existing tests pass
- [ ] 7.2 Test: `build-image.sh proxy` builds successfully
- [ ] 7.3 Test: proxy container starts and responds to HTTP requests
- [ ] 7.4 Test: forge container can `npm install` through proxy
- [ ] 7.5 Test: forge container cannot reach non-allowlisted domains
- [ ] 7.6 Test: `--log-proxy` shows proxy request events
- [ ] 7.7 Test: `--log-enclave` shows network lifecycle events
