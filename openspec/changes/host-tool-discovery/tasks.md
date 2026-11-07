# Tasks — host-tool-discovery

Packet orders in brackets.

## 1. First slice [1969-7qm7]

- [x] 1.1 `host_tools.rs`: rename table, `canonical`, grouped index, `instructions`, `tillandsias.index`, deprecated descriptors listed last
- [x] 1.2 `mcp_socket.rs`: canonical names in `tools/list`, alias resolution before dispatch, `initialize.instructions`
- [x] 1.3 `studio.rs`: `webstudio.*` names and descriptions that say what they start
- [x] 1.4 `studio_tool.rs`: `studio_unavailable` remedy names `.tillandsias/config.toml`
- [x] 1.5 Pin tests in `tray/mod.rs` and the discovery fixtures in `mcp_socket.rs` (alias equivalence, one schema under both names, descriptions name what they start, `initialize` carries the index)
- [x] 1.6 Forge guidance, `web-services.md` and the bundled cheatsheet `tooling/host-tools-index.md` carry the index and the rename table

## 2. Later slices

- [ ] 2.1 Register the socket under a name for the whole surface (e.g. `host-tools`) beside `host-browser` for one release, in the four harness configs, `register-experts.sh`, `test-codex-mcp-registration.sh`, the Lua guards that name `host-browser`, `forge-quick-intro`, `lib-common.sh` and `forge-welcome.sh`; then drop `host-browser`
- [ ] 2.2 `studio.start {}` / `studio.status {}`: the forge agent starts the ComfyUI appliance on demand through the socket, sized by the forge budget, never at launch, no tray entry (order 1969-cfyt); `studio.run_workflow` refuses with `studio_unavailable` naming `studio.start`, and `imagegen_studio::ensure_if_enabled` leaves the launch path
- [ ] 2.3 `webstudio.open` opens the studio window from the lane (order 2025-e6mi) and `webstudio.publish_request` hands off to the deploy tool (order 1866-9696)
- [ ] 2.4 Remove the ten deprecated aliases one release after 1969-7qm7 ships; update `cold-start-acceptance.lua`, `local_web_preview_e2e.rs` and the `flutter` shim to the canonical names first
- [ ] 2.5 Mirror the grouped index in `tillandsias-doctor` (its per-server lines name the groups the socket serves)
