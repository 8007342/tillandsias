## ADDED Requirements

### Requirement: S7 — app network with the router's second leg

A launched app container SHALL run in posture **S7**: attached to its own `tillandsias-app-<app>` internal network only, with the router connected as a second leg and, for the `allowlist` and `open` egress postures, the proxy connected as well. S7 is expressed by `app_network.rs` `fn build_app_network_args` and the router's runtime `network connect`; it is the only posture in which the router has more than one network, and the router SHALL still have no NAT leg. Posture numbers are permanent; S7 is appended, S4 stays retired.

#### Scenario: an app builder sets any other network

- **WHEN** an app run-argument builder names `tillandsias-enclave`, `tillandsias-egress` or omits `--network`
- **THEN** the membership guard refuses the build and names S7 as the posture an app must take
