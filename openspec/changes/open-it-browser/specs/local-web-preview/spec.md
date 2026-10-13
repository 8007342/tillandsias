## MODIFIED Requirements

### Requirement: HTTPS routing and honest trust
<!-- req-id: 36a4c4e1 -->

The successful preview URL MUST be
`https://www.<project>.localhost[:actual_tls_port]`, routed by the existing
`tillandsias-router` using the existing local CA machinery. A TLS listener may
be added on a loopback-only port; existing HTTP routes remain compatible. The
preview container MUST NOT publish a host port. Keep Caddy admin private and
use the existing in-container reload mechanism. TLS certificate SAN must cover
the actual returned multi-label hostname; `*.localhost` alone does not cover
`www.<project>.localhost`. Probe with the actual hostname/SNI and CA verification.

Narrow routing amendment proposed by this draft: the routing spec's
exactly-one-host-address rule continues to govern the existing HTTP ingress
`127.0.0.1:<http_host_port> -> :8080`. For this preview profile only, permit
one additional `127.0.0.1:<tls_host_port>` mapping to the router's TLS listener.
The two ingress mappings are the complete allowed set; no wildcard-address,
admin-port or per-service publication is permitted. Preserve the HTTP listener,
its port selection and existing routes. This is a draft exception pending
integrator reconciliation/verification, not activation of a changed routing spec.

Trust of the CA in a runtime container is NOT evidence of host-browser trust.
Default `host_trust=unknown` unless a host-side verification actually establishes
it. An explicitly CA-verified curl is transport evidence, not browser-trust
evidence. A browser trust failure must be reported as such without calling the
runtime stopped. MUST NOT run trust-store installation commands, disable TLS
verification, or silently return HTTP as a successful HTTPS preview.

**Approved Chromium window sibling (operator direction 2026-10-12, superseding
"no Chromium sibling is approved").** The agent MAY open the preview in a
browser window sibling, as in "start this project locally and open it":
`browser.open` on the returned URL, running in the `tillandsias-chromium-framework`
container (or another engine of `spec:browser-window-modes`). That window:
- runs on its own internal network that reaches only this project's router
  routes through a per-window SNI-bound forwarder;
- trusts the router CA by SPKI pin inside its container
  (`--ignore-certificate-errors-spki-list`). That is pinning, not disabled
  verification, and it changes no host trust-store bytes;
- is evidence of in-window trust only. It MUST NOT be reported as
  `host_trust`, which keeps its meaning above.

The preview URL's TLS port MUST be admitted by the browser allowlist (order
1649-xqet).

#### Scenario: The preview opens in the approved window sibling

- **WHEN** `publish_local` returns `https://www.<project>.localhost:<tls_port>`
  and the agent calls `browser.open` on it
- **THEN** a browser engine container renders the page over verified TLS
- **AND** `host_trust` is unchanged by that window
- **AND** no host trust-store bytes are changed

#### Scenario: Host lacks CA trust

- **WHEN** the backend and CA-verified HTTPS route work but browser trust fails
- **THEN** status distinguishes healthy runtime/TLS from untrusted or unknown host trust
- **AND** diagnostics explain the separate approval needed to install trust
- **AND** no trust-store bytes are changed
