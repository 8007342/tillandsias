# Tasks: fix-podman-machine-host-aliases

## Investigation
- [x] Reproduce on Windows 11 + podman 5.8 with `tillandsias <project> --debug` → confirmed `Connection refused` from `git clone git://localhost:9418/...`
- [x] Verify in a probe container that `--add-host alias:host-gateway` adds `169.254.1.2 alias` to `/etc/hosts` and that connectivity to a host-published port works

## Fix
- [x] Change `--add-host alias:127.0.0.1` → `--add-host alias:host-gateway` in `src-tauri/src/launch.rs:185`
- [x] Revert `rewrite_enclave_env` to be a no-op (keep function as a future hook)
- [x] Update tests:
  - [x] `port_mapping_uses_friendly_aliases_resolved_via_host_gateway` — assert friendly-alias env vars + `--add-host alias:host-gateway` flags
  - [x] `rewrite_enclave_env_passes_through_after_host_aliases_fix` — assert no-op behavior
- [x] Add `// @trace spec:enclave-network, spec:fix-podman-machine-host-aliases` at touched sites

## Verify
- [x] `cargo check --workspace` clean
- [x] `cargo test launch::tests::port_mapping_uses_friendly_aliases_resolved_via_host_gateway` — passes
- [x] `cargo test launch::tests::rewrite_enclave_env_passes_through_after_host_aliases_fix` — passes
- [x] End-to-end on Windows 11 + podman 5.8: `tillandsias <project> --bash` → `Cloning into '/home/forge/src/test1'... warning: You appear to have cloned an empty repository.` (no `Connection refused`)
- [x] All four enclave containers up with their ports published; forge sees them via the friendly aliases

## Cheatsheet
- [x] Document in commit body why `127.0.0.1` was wrong (forge's own loopback) vs `host-gateway` (resolves to gateway IP at runtime)

## Trace + commit
- [x] OpenSpec validate
- [ ] Commit body includes `https://github.com/8007342/tillandsias/search?q=%40trace+spec%3Afix-podman-machine-host-aliases&type=code`
