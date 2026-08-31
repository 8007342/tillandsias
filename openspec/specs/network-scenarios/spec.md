<!-- @trace spec:network-scenarios -->
# network-scenarios Specification

## Status

active

## Purpose

Name every network posture a Tillandsias-managed container can run in, so an
operation declares which one it is using rather than assembling `--network`
arguments ad hoc. Published from order 245 §5 P5; every posture below was
verified against the tree on 2026-08-30 rather than carried over from the
draft catalog.

**Scenario numbers are permanent.** S4 is retired and its number is NOT reused,
for the same reason order tokens are never renumbered: the label leaks into
comments, audits and commit messages, and a pushed reference cannot be
corrected.

## Requirements

### Requirement: Every container declares a network posture

Every Tillandsias-managed container MUST run in exactly one of the postures
below, and the posture MUST be a deliberate choice — including the choice to
set no network at all.

@trace spec:network-scenarios, spec:enclave-network, spec:proxy-container, order:245

| id | posture | how it is expressed | takers (verified 2026-08-30) |
|---|---|---|---|
| **S1** | enclave-internal, no proxy env | `ENCLAVE_NET` / `ENCLAVE_ONLY_NET`, no `proxy_env_args` | vault (`vault_bootstrap.rs` `fn launch_vault_container`), router, catalog service, observatorium web |
| **S2** | enclave + proxy egress | enclave network **plus** `main.rs` `fn proxy_env_args` or `fn apply_proxy_env` | forge, inference, the git mirror (enclave-only since order 606-9wqd), nix cache |
| **S3** | dual-homed | `main.rs` `const ENCLAVE_EGRESS_NETS` | the proxy (`fn build_proxy_run_args`) — the only spec-sanctioned taker — and the provider-login helper (`fn run_provider_login`), whose dual-home is an unadjudicated divergence, see below |
| **S5** | build netns | `podman build` default netns with `--dns 8.8.8.8` (`tillandsias-podman` `client.rs`) | every image build |
| **S6** | default rootless netns | **no `--network` argument at all** | the project browser (`main.rs` `fn build_project_browser_spec`, which sets no network) |

**S6 is new here and is a description, not a design.** The draft catalog ran
S0-S5 and its own last row admitted "the browser runs on a default-netns
posture the catalog has no name for". Verified: `build_project_browser_spec`
contains zero `.network(` calls across its whole body, so the browser inherits
podman's default rootless netns by OMISSION. A posture reached by omission is
the one most likely to be adopted accidentally, which is exactly why it needs a
name.

#### Scenario: A posture reached by omission is still a declared posture
- **WHEN** a container builder sets no `--network` argument
- **THEN** that is S6 and MUST be deliberate
- **AND** it MUST NOT be assumed to mean "isolated": the default rootless netns
  has outbound access and is not the enclave

#### Scenario: S3 is not self-service
- **WHEN** a container is given both the enclave and egress legs
- **THEN** the proxy is the only sanctioned taker
- **AND** any other dual-home is a divergence requiring adjudication — the
  provider-login helper's is recorded and still unadjudicated in
  `plan/issues/git-mirror-egress-spec-divergence-audit-2026-08-10.md`

### Requirement: S0 is not a scenario, and S4 is retired

**S0 (no network) MUST NOT be published as an available posture.** The draft
listed it; nothing uses it, and a named posture with no taker is a label
without wiring. If an operation ever needs a genuinely network-less container,
S0 is minted then, with its taker.

**S4 (host network) is RETIRED and MUST NOT return.** Order 615-x3b8 moved the
browser off host network; what prevents its return is stronger than the draft
recorded.

@trace spec:network-scenarios, order:615-x3b8, order:245

#### Scenario: host networking is refused by an allowlist, not a denylist
- **WHEN** a passthrough option is offered to a container launch
- **THEN** `tillandsias-podman` `fn is_allowlisted_passthrough_option` admits it
  only if it begins with `--device=` and carries a value
- **AND** `fn disallowed_passthrough_options` returns everything else, so
  `--network=host` is refused because NOTHING but a device flag is permitted —
  not because host networking is named
- **AND** this is deliberately stronger than a denylist, which would have to
  enumerate every dangerous flag in advance and would silently admit the next
  one nobody thought of

## Invariants

- Scenario numbers are permanent; a retired scenario's number is never reused.
- A posture with no taker is not published (see S0).
- S3 membership changes require adjudication, not a commit.

## Litmus Tests

The enumeration half of P5's proposed litmus already exists:
`scripts/check-enclave-membership-documented.sh` (pinned by
`litmus:enclave-membership-documented`) finds every enclave attach site and
refuses any the enclave-network spec does not name. What it does NOT yet do is
require each site to name a SCENARIO — that needs scenario constants in code,
which is a change to the launch builders and not a documentation act.

## Sources of Truth

- `openspec/specs/enclave-network/spec.md` — enclave membership, symbol-anchored
- `openspec/specs/proxy-container/spec.md` — the NO_PROXY and Node egress contract
- `plan/issues/network-architecture-audit-2026-07-09.md` §2 — the draft catalog this supersedes
