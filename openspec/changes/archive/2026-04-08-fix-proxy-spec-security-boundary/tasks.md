# Tasks: Fix proxy-container spec security boundary

## Tasks

- [x] Read current (stale) spec at `openspec/specs/proxy-container/spec.md`
- [x] Read implementation: `src-tauri/src/ca.rs`, `images/proxy/squid.conf`, `images/proxy/entrypoint.sh`
- [x] Read allowlist: `images/proxy/allowlist.txt`
- [x] Read proxy startup: `handlers.rs` `ensure_proxy_running`, `inject_ca_chain_mounts`
- [x] Read image build bypass logic: `handlers.rs` `run_build_image_script`
- [x] Create delta spec at `specs/proxy-container/spec.md`
- [x] Update main spec at `openspec/specs/proxy-container/spec.md`
- [x] Verify all claims in spec match code
- [x] Commit with trace annotation
