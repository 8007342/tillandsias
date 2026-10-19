## MODIFIED Requirements

### Requirement: Container attachment to enclave network

The system MUST attach every Tillandsias-managed container to the `tillandsias-enclave` network, EXCEPT app containers, which take posture S7 on their own `tillandsias-app-<app>` network. Only the proxy MUST additionally be attached to the egress network for external access. The router (`main.rs` `fn build_router_run_args`) and the proxy (`fn build_proxy_run_args`) are the only members that may be connected at runtime to additional networks, and only to networks named `tillandsias-app-*`; `scripts/lua/check-enclave-membership-documented.lua` refuses any other runtime `network connect` and any app builder that names the enclave.

#### Scenario: the router gains an app leg

- **WHEN** an app starts
- **THEN** `podman network connect tillandsias-app-<app> tillandsias-router` is the only connect issued for the router, and no connect names `tillandsias-egress`
