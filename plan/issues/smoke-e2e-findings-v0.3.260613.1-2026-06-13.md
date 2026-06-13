### Work Packet: smoke-finding/forge-base-image-missing-in-init

- id: `smoke-finding/forge-base-image-missing-in-init`
- owner_host: linux
- capability_tags: [rust, podman, testing, release]
- status: claimed
- discovered_by: `/smoke-curl-install-and-test-e2e` on release `v0.3.260613.1`
- evidence:
  - `target/smoke-e2e/03-init.log` — Error: creating build container: unable to copy from source docker://localhost/tillandsias-forge-base:latest: initializing source docker://localhost/tillandsias-forge-base:latest: pinging container registry localhost: Get "http://localhost/v2/": dial tcp [::1]:80: connect: connection refused
- repro:
  - `tillandsias --debug --init`
- next_action: >
    The recent refactor that split the `forge` Containerfile into `Containerfile.base` and `Containerfile` only updated `scripts/build-image.sh` for local development. The production `tillandsias --init` Rust code (likely in `crates/tillandsias-cli/src/init.rs` or `images.rs`) still only builds `Containerfile` directly, causing it to fail because `localhost/tillandsias-forge-base:latest` doesn't exist. Update the Rust `init` routine to build `Containerfile.base` as `tillandsias-forge-base:latest` before building `Containerfile`.
- events:
  - type: discovered
    ts: `2026-06-13T05:13:45Z`
    agent_id: `92f6f1e1-6dd1-4082-bb27-f54f7cbd77ec`
    host: linux
  - type: claim
    ts: `2026-06-13T06:41:30Z`
    agent_id: `linux-macuahuitl-codex-20260613T064130Z`
    host: linux
    lease_id: `7d22726a7511`
    expires_at: `2026-06-13T10:41:30Z`
