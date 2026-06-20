# Tasks

## 1. Specification and plan surface

- [ ] 1.1 Add a top-level NanoClawV2 orchestration spec.
- [ ] 1.2 Add a plan issue packet that captures the launch, broker, and smoke
  scope.
- [ ] 1.3 Update the active plan frontier so the new work is discoverable by
  `/advance-work-from-plan`.

## 2. Container and launch path

- [x] 2.1 Add a baked `nanoclawv2` image to the image build list.
      (2026-06-19, slice 1: images/nanoclawv2/Containerfile + build-image.sh registration)
- [x] 2.2 Add the tray launcher leaf `🦞 NanoClawV2` beside the existing
  per-project actions. (Launcher leaf complete: LaunchKind, LeafAction, menu
  construction, click dispatch, launch handler, and container spec all wired.)
- [x] 2.3 Wire the launcher to start only an allowlisted NanoClawV2 container
  for the selected project. (Image name hardcoded to nanoclawv2 in
  launch_project_action; registered in Rust image builder for --init build.)

## 3. Host orchestration surface

- [x] 3.1 Add the smallest host control surface needed for approved NanoClawV2
  actions. (2026-06-20: crates/tillandsias-nanoclawv2-mcp — Unix-socket MCP
  server, 5-tool allowlist, project-scope enforcement, tray launch wiring.)
- [x] 3.2 Seed only the approved skills and MCP servers. (2026-06-20:
  images/nanoclawv2/config-overlay/opencode/config.json — nanoclaw-host MCP
  only, locked instructions; nanoclaw-host.sh socat bridge.)
- [x] 3.3 Keep credentials and raw Podman access on the host side. (2026-06-20:
  by design — nanoclaw-mcp tools run as host subprocesses; no Vault token or
  Podman socket is passed into the container.)

## 4. Smoke and verification

- [ ] 4.1 Add a launch smoke that verifies the NanoClawV2 container starts.
- [ ] 4.2 Add a broker smoke that proves one approved action works.
- [ ] 4.3 Extend the published-release smoke so NanoClawV2 launch remains
  validated after release.
- [ ] 4.4 Record every failure as a dated plan issue packet.

---

## Slice Decomposition (≤2h per slice)

| Slice | Tasks | Scope | Est. |
|-------|-------|-------|------|
| 1 | 2.1 | Image infrastructure: Containerfile, entrypoint, config overlay, build-image.sh registration | 1h |
| 2 | 2.2, 2.3 | Tray launcher leaf: Rust mod.rs changes, launch wiring, container allowlist | 2h |
| 3 | 3.1, 3.2, 3.3 | Host orchestration surface: MCP broker, allowlist enforcement, credential isolation | 2h |
| 4 | 4.1, 4.2, 4.3, 4.4 | Smoke coverage: launch smoke, broker smoke, release smoke, failure recording | 2h |


