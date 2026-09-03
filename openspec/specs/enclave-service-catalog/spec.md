# enclave-service-catalog Specification

@trace spec:enclave-service-catalog

## Status

active

## Purpose

The catalog of publishable enclave services: how a project's container (today
the single fixed category `WEB`) is brought up on the enclave network and
exposed through the reverse proxy under a friendly local URL. Orders 357/363/
364 built the surface (`--publish-local`, the MCP `publish_local` tool, and
`build_catalog_service_run_args`); this spec pins what any category must
honour. Registry-asserted (litmus:service-catalog-allowlist-shape) before the
file existed — order 877 closed that ghost.

## Requirements

### Requirement: The catalog is an allowlist, not a namespace
<!-- req-id: 924d63ac -->

A forge may request only service categories the catalog declares (today:
`WEB`, nothing else until order 358 generalizes). Requests outside the
catalog are refused host-side; the guest cannot mint categories.

#### Scenario: Unknown category refused

- **WHEN** a guest requests publication of a category the catalog does not
  declare
- **THEN** the host refuses the request without launching anything
  (litmus:service-catalog-allowlist-shape)

### Requirement: Published services join the enclave by fixed name
<!-- req-id: 28666097 -->

A catalog service runs on the enclave network as
`tillandsias-<project>-<category>` (e.g. `tillandsias-myapp-web`) so the
router reaches it by name, with the category's fixed resource-share rule —
never an agent-chosen name or share.

#### Scenario: Router resolves the published container

- **WHEN** a WEB service is published for project `p`
- **THEN** the container is reachable from the router as
  `tillandsias-p-web` and the operator receives the friendly https URL

### Requirement: Public routes drop auth deliberately, never by default
<!-- req-id: aba568d1 -->

A catalog route carries `public: false` unless explicitly published; only an
explicitly `public` route is rendered as a bare reverse_proxy with no
forward_auth gate (the user's own localhost dev server). Every other route
keeps its auth chain.

#### Scenario: Default keeps the auth chain

- **WHEN** a route is added without an explicit `public` flag
- **THEN** the rendered proxy config MUST include the forward_auth gate

## Sources of Truth

- `crates/tillandsias-headless/src/main.rs` — `--publish-local`,
  `build_catalog_service_run_args`, route rendering
- `openspec/specs/subdomain-routing-via-reverse-proxy/` — the routing side
- `openspec/litmus-bindings.yaml` (spec_id `enclave-service-catalog`)
