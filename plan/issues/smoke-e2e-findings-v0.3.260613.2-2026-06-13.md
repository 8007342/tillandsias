# Smoke E2E Findings - Release v0.3.260613.2 - 2026-06-13

Discovered by `/smoke-curl-install-and-test-e2e`.

Run summary: the canonical curl install passed, the installed binary reported
`v0.3.260613.2`, and `podman system reset --force` left an empty store. Fresh
`tillandsias --debug --init` built `forge-base` successfully, including all
pinned release assets, but the final `forge` image failed because the published
runtime bundle did not contain the `skills/` build-context directory. The smoke
halted before the OpenCode continuous-enhancement step.

### Work Packet: smoke-finding/forge-skills-missing-from-runtime-assets

- id: `smoke-finding/forge-skills-missing-from-runtime-assets`
- owner_host: linux
- capability_tags: [rust, podman, testing, release, forge]
- status: done
- discovered_by: `/smoke-curl-install-and-test-e2e` on release `v0.3.260613.2`
- evidence:
  - `target/smoke-e2e/03-init.log:3779` - `SUCCESS forge-base`
  - `target/smoke-e2e/03-init.log:3868` - `STEP 43/51: COPY skills/ /opt/skills/`
  - `target/smoke-e2e/03-init.log:3869` - published runtime build context reports `copier: stat: "/skills": no such file or directory`
  - `target/smoke-e2e/03-init.log:3921` - `Error: Failed to build 1 image(s): forge`
- repro:
  - From an empty Podman store, curl-install release `v0.3.260613.2` and run `tillandsias --debug --init`.
- next_action: >
    Add the forge `images/default/skills/` tree to the headless embedded runtime
    asset manifest and materialization path, then add an embedded-asset
    regression test that requires every Containerfile COPY source to exist in
    the published runtime build context.
- events:
  - type: discovered
    ts: `2026-06-13T07:22:43Z`
    agent_id: `linux-macuahuitl-codex-20260613T064130Z`
    host: linux
  - type: claim
    ts: `2026-06-14T00:14:17Z`
    agent_id: `linux-tlatoani-gemini-20260614T001417Z`
    host: linux
    lease_id: `lease-linux-forge-skills-missing-20260614T001417Z`
    expires_at: `2026-06-14T04:14:17Z`
  - type: completed
    ts: `2026-06-14T00:17:35Z`
    agent_id: `linux-tlatoani-gemini-20260614T001417Z`
    host: linux
    lease_id: `lease-linux-forge-skills-missing-20260614T001417Z`
    evidence_refs:
      - `commit:2b4bf178`
      - `cargo test -p tillandsias-headless`
      - `./build.sh --test`
