# Research: Compile-Time Container Dependency Model

**Status:** `ready`
**Owner:** linux
**Date:** 2026-06-27
**Kind:** research
**Trace:** `spec:proxy-container`, `spec:tillandsias-vault`, `spec:remote-projects`

## Motivation (operator request)

> "We're going to need a compiled model of container dependencies, so launching a
> container would fail at compile time if dependencies aren't met. As we add
> containers they should depend on each other transparently."

Four consecutive P0s (orders 116, 118, 119, and proxy-not-started) all share one
root cause: a container/operation has an **implicit runtime dependency** that is
only discovered when it fails in production:

| Bug | Implicit dependency that was unmet |
|---|---|
| 116 build proxy poison | build step must NOT have the runtime proxy in env |
| 118 vault exec env | host `vault` exec needs VAULT_ADDR/TOKEN/skip-verify |
| 119 vault no_proxy | container→`vault:8200` must bypass the egress proxy |
| proxy-not-started | gh-login/git container requires `tillandsias-proxy` running |

Each was fixed by hand-adding an `ensure_X` call or an env tweak at one more call
site. There is no single source of truth that says "container/op Y depends on
{vault, proxy, enclave-network, egress, ca-bundle, …}", so every new flow
re-derives (and forgets) the prerequisites.

## Goal

A declarative, **compile-time-checked** dependency model where:

1. Each container/service declares what it requires (other services running,
   networks present, secrets/leases mounted, CA bundle, proxy egress, direct
   egress, etc.).
2. Launching a container is only possible through an API that *proves* the
   dependencies are satisfied — an unmet dependency is a **compile error**, not a
   runtime "error connecting to proxy".
3. Adding a new container wires its dependencies in one place and every launch
   path transparently inherits the correct bring-up order.

## Design Questions to Resolve (deliverable of this packet)

1. **How much can Rust's type system enforce vs. what stays runtime-checked?**
   - Option A — *typestate / capability tokens*: launching `GhLoginContainer`
     requires a `ProxyRunning` + `VaultRunning` token, obtainable only from
     `ensure_proxy()` / `ensure_vault()`. Missing token → won't compile. Strong,
     but tokens for "is it actually healthy right now" still need a runtime probe;
     the type only proves the call was *sequenced*.
   - Option B — *const dependency graph + build-time validation*: a `const`/static
     declarative graph (`Service { name, requires: &[Service] }`), validated for
     cycles/missing nodes by a `#[test]` or a build.rs, with a single runtime
     `ensure(service)` that topologically brings up prerequisites. Compile-time
     catches graph *well-formedness*; runtime enforces *liveness*.
   - Option C — *hybrid*: const graph for declaration + topo order; typestate
     tokens on the launch API so call sites can't skip `ensure`. Likely the
     sweet spot.
   - Decide which, with a worked example for the gh-login → {vault, proxy,
     enclave-net, egress, ca-bundle} case.

2. **What is a "dependency"?** Enumerate the dependency kinds the model must
   express: service-running, network-present, CA-bundle-present, podman-secret/
   AppRole-lease-mounted, proxy-egress-required, direct-egress-required,
   image-built-at-version, host-keychain-token-available, vault-unsealed.

3. **Bring-up ordering & idempotence.** The model must produce a topological
   bring-up (vault before its dependents, proxy before egress users) and every
   `ensure_*` must stay idempotent + cheap when already satisfied.

4. **Healthy vs. present.** A compile-time token can prove "ensure was called",
   not "the container is healthy now". Define the runtime liveness contract that
   complements the static check (reuse `ContainerHealthFacade`).

5. **Where does it live?** Candidate: a new module in `tillandsias-podman`
   (the canonical podman facade) so both headless and future callers share it.
   Confirm it does not create a cycle with `tillandsias-headless`.

6. **Version coupling.** Dependencies include "image built at the running
   binary's VERSION". The model should make version-mismatched launches a
   declared dependency (today a mismatch silently triggers a rebuild — see the
   diagnostic-version-skew note in the proxy-not-started issue).

7. **Drift protection.** A litmus/test that fails if a new container is added to
   the launch paths without a dependency declaration (so the model can't be
   bypassed the way `ensure_proxy` was missed).

## Non-Goals

- Replacing podman/quadlet. This is an in-process bring-up model, not a new
  orchestrator. (Evaluate whether podman `--requires`/quadlet `Requires=` covers
  part of it, but the compile-time guarantee is the differentiator.)

## Deliverable

A design verdict appended here choosing A/B/C with: the dependency-kind taxonomy,
the launch API sketch, the module location, the runtime-liveness contract, and a
drift-protection test definition — enough that
`container-dependency-graph-impl-2026-06-27.md` can be sliced into implementable
packets.

## Related

- `plan/issues/proxy-not-started-standalone-flows-2026-06-27.md` — the bug that motivated this
- `plan/issues/vault-service-dns-no-proxy-2026-06-27.md`, `…vault-exec-env-regression…`, `…init-proxy-poisons-build…`
- `project_enclave_proxy_exemption_pattern` (agent memory) — the recurring proxy-exemption theme
