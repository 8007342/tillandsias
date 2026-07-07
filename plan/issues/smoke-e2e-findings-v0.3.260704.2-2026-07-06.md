### Work Packet: smoke-finding/semanage-permission-denied

- id: `smoke-finding/semanage-permission-denied`
- owner_host: linux
- capability_tags: [podman, runtime]
- status: ready
- discovered_by: `/smoke-curl-install-and-test-e2e` on release `v0.3.260704.2`
- evidence:
  - `target/smoke-e2e/03-init.log` — `libsemanage.semanage_create_store: Could not read from module store... (Permission denied)`
- repro:
  - `tillandsias --debug --init`
- next_action: >
    Investigate SELinux semanage permission denied during init.
- events:
  - type: discovered
    ts: `2026-07-06T17:15:32Z`
    agent_id: `linux-immutable-orchestrator-20260706`
    host: linux_immutable

### Work Packet: smoke-finding/vault-etc-hosts-permission-denied

- id: `smoke-finding/vault-etc-hosts-permission-denied`
- owner_host: linux
- capability_tags: [podman, vault, runtime]
- status: ready
- discovered_by: `/smoke-curl-install-and-test-e2e` on release `v0.3.260704.2`
- evidence:
  - `target/smoke-e2e/03-init.log` — `[tillandsias-vault] /etc/hosts update failed: Permission denied (os error 13)`
- repro:
  - `tillandsias --debug --init`
- next_action: >
    Investigate why the vault container is trying to update /etc/hosts and failing on immutable linux, possibly a rootless podman issue.
- events:
  - type: discovered
    ts: `2026-07-06T17:15:32Z`
    agent_id: `linux-immutable-orchestrator-20260706`
    host: linux_immutable

### Work Packet: smoke-finding/opencode-unknown-image-type-curl

- id: `smoke-finding/opencode-unknown-image-type-curl`
- owner_host: linux
- capability_tags: [rust, podman]
- status: ready
- discovered_by: `/smoke-curl-install-and-test-e2e` on release `v0.3.260704.2`
- evidence:
  - `target/smoke-e2e/04-opencode.log` — `Error: Unknown image type: curl`
- repro:
  - `env TILLANDSIAS_NO_TRAY=1 tillandsias . --opencode --prompt "Use the /meta-orchestration skill"`
- next_action: >
    Fix the forge launcher argument parsing or image determination logic that causes 'Unknown image type: curl' when launching.
- events:
  - type: discovered
    ts: `2026-07-06T17:15:43Z`
    agent_id: `linux-immutable-orchestrator-20260706`
    host: linux_immutable
