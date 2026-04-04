## 1. Telemetry Events Audit

- [ ] 1.1 Verify `ensure_enclave_network()` emits `[enclave]` events with `spec = "enclave-network"`
- [ ] 1.2 Verify `ensure_proxy_running()` emits `[proxy]` events with `spec = "proxy-container"`
- [ ] 1.3 Verify `ensure_git_service_running()` emits `[git]` events with `spec = "git-mirror-service"`
- [ ] 1.4 Verify `ensure_inference_running()` emits events with `spec = "inference-container"`
- [ ] 1.5 Verify shutdown functions emit cleanup events
- [ ] 1.6 Verify proxy health check emits events

## 2. Documentation

- [ ] 2.1 Update CLAUDE.md with enclave architecture section
- [ ] 2.2 Update enclave-architecture.md cheatsheet — mark all phases complete
- [ ] 2.3 Update logging-levels.md cheatsheet with new accountability windows
- [ ] 2.4 Final @trace annotation sweep across all new source files

## 3. Archive OpenSpec Changes

- [ ] 3.1 Archive enclave-proxy-network
- [ ] 3.2 Archive git-mirror-service
- [ ] 3.3 Archive forge-offline-isolation
- [ ] 3.4 Archive inference-container
- [ ] 3.5 Archive enclave-telemetry-polish
