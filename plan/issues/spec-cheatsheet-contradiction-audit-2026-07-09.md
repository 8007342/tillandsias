# Spec & Cheatsheet Organic Growth Contradiction Audit

**Date:** 2026-07-09
**Classification:** audit+documentation
**Host:** any
**Observed by:** linux-big-pickle-20260709

## Observation

The project has 167 OpenSpec spec directories and an unknown number of cheatsheets
in `docs/cheatsheets/`. These grew organically as features were added by multiple
agents across multiple hosts. There is no cross-referencing mechanism to detect
contradictions between specs, or between specs and the actual implementation.

Known risk areas:

1. **Network topology**: `openspec/specs/enclave-network/`, `openspec/specs/proxy-container/`,
   `openspec/specs/vsock-transport/`, `openspec/specs/container-dependency-graph/` may
   contradict each other on the network topology for each runtime.

2. **Credential management**: `openspec/specs/tillandsias-vault/`, `openspec/specs/secrets-management/`,
   `openspec/specs/podman-secrets-integration/`, `openspec/specs/native-secrets-store/`,
   `openspec/specs/github-credential-health/` may have overlapping or contradictory
   policies for where secrets live and how they're injected.

3. **Tray UX**: `openspec/specs/tray-ux/`, `openspec/specs/tray-minimal-ux/`,
   `openspec/specs/simplified-tray-ux/`, `openspec/specs/tray-progress-and-icon-states/`,
   `openspec/specs/tray-menu/` may have diverging UX philosophies.

4. **Build/Init**: `openspec/specs/init-command/`, `openspec/specs/init-incremental-builds/`,
   `openspec/specs/build-script-architecture/`, `openspec/specs/build-lock/` may specify
   different build ordering or dependency resolution strategies.

## Impact

Agents implementing features based on one spec may inadvertently violate another spec.
Without cross-referencing, contradictory specs silently proliferate, reducing the
value of the spec system as an authoritative source of truth.

## Required Agents

At least 3 agents must verify this packet as complete:
- `claude-opus-highthink`
- `opencode-bigpickle`
- `antigravity-gemini`

## Deliverable

1. **Cross-Reference Matrix**: Every spec in `openspec/specs/` mapped to its
   dependencies and dependents. Identify specs with no dependents (potentially
   orphaned) and specs with overlapping scope.

2. **Contradiction Report**: Specific pairs/triples of specs that make contradictory
   claims about the same subject. Include file:line references.

3. **Reconciliation Plan**: For each contradiction, a recommended resolution (which
   spec is authoritative, or a new unified spec that supersedes both).

4. **Cheatsheet Audit**: Cross-reference `docs/cheatsheets/` against the spec matrix.
   Flag cheatsheets that contradict the spec they reference.

5. **Litmus Recommendation**: Minimum set of litmus tests needed to prevent spec
   drift (e.g., `litmus:spec-proxy-enclave-network-consistency`).
