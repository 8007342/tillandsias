# Implementation: Compile-Time Container Dependency Model

**Status:** `pending` (blocked on research verdict)
**Owner:** linux
**Date:** 2026-06-27
**Kind:** enhancement
**Depends on:** `container-dependency-graph-research-2026-06-27.md`
**Trace:** `spec:proxy-container`, `spec:tillandsias-vault`

## Intent

Implement the dependency model chosen by the research packet so that launching a
container is only possible when its declared dependencies are satisfied, with as
much enforcement as possible at compile time and the remainder as a single
idempotent runtime bring-up. Adding a new container declares its deps in one
place; all launch paths inherit correct, ordered bring-up transparently.

## Sliced Packets (refine after research verdict)

### Slice 1 — Dependency taxonomy + declarations (`ready` after research)
- Define the dependency-kind enum (service-running, network-present, ca-bundle,
  secret/lease, proxy-egress, direct-egress, image-at-version, vault-unsealed,
  keychain-token) in `tillandsias-podman`.
- Declare the current containers and their deps: `vault` (network, unseal),
  `proxy` (enclave+egress nets, ca-bundle), `git`/`gh-login` (vault, proxy,
  enclave+egress, ca-bundle, vault-lease), `inference`, `forge`/`forge-base`,
  `chromium-*`, `web`.
- Verifiable closure: a `#[test]` that the graph is acyclic and every declared
  dependency names a known node.

### Slice 2 — Topological `ensure(service)` bring-up
- One idempotent entry point that brings up a service and its prerequisites in
  topological order, replacing the ad-hoc `ensure_vault_running` /
  `ensure_proxy_running` call chains (keep thin wrappers for compatibility).
- Verifiable closure: unit test asserting bring-up order for
  `ensure(GhLogin)` = [enclave-net, egress-net, ca-bundle, vault, proxy, …].

### Slice 3 — Compile-time launch API (typestate tokens) [if research picks B/C]
- Launch functions take capability tokens (`ProxyUp`, `VaultUp`, …) obtainable
  only from `ensure(...)`. Removing an `ensure` call → call site won't compile.
- Migrate `run_github_login` and `run_list_cloud_projects` to the token API as
  the first consumers (they are the proven-broken cases).
- Verifiable closure: a `trybuild`/compile-fail test proving a launch without the
  required token fails to compile.

### Slice 4 — Runtime liveness contract
- Pair the static "ensure was sequenced" guarantee with a runtime health probe
  (`ContainerHealthFacade`) so a token also implies a fresh liveness check.
- Verifiable closure: test that a stopped dependency is detected and re-ensured.

### Slice 5 — Drift protection
- Litmus/test that fails if a container-launch site is added without a dependency
  declaration (prevents re-introducing the `ensure_proxy`-was-missing class).
- Verifiable closure: the litmus is pinned and runs in the instant phase.

## Exit Criteria

- All current launch paths route through the dependency model.
- `run_github_login` / `run_list_cloud_projects` cannot be written to skip the
  proxy/vault bring-up without a compile error (or, if model B, without failing
  the drift litmus).
- Acyclic-graph + bring-up-order + (if applicable) compile-fail tests are green.
- `./build.sh --check` and `--test` pass.
- The four motivating P0s could not recur silently: a missing prerequisite is a
  compile error or a pinned-litmus failure, not a production "error connecting to
  proxy".

## Related

- `plan/issues/container-dependency-graph-research-2026-06-27.md` — design verdict (blocker)
- `plan/issues/proxy-not-started-standalone-flows-2026-06-27.md` — motivating bug
