## ADDED Requirements

### Requirement: Forward proxy recognises `*.localhost` as enclave-internal

The Squid proxy SHALL allow `*.localhost` destinations and forward
them to a sibling reverse-proxy container at `router:80` instead of
attempting external resolution.

This lets forge agents run `curl http://<project>.<service>.localhost/`
through their existing `HTTP_PROXY=http://proxy:3128` and reach
enclave-local services without any client-side configuration.

`*.localhost` MUST never be forwarded externally — by RFC 6761 these
hostnames are loopback-only, and a leak past the proxy to an external
DNS server would itself be a violation. The Squid config MUST contain
both an `acl localhost_subdomain dstdomain .localhost` and a
`cache_peer router parent 80 0` directive (or equivalent), with
`cache_peer_access router allow localhost_subdomain` and
`never_direct allow localhost_subdomain`.

#### Scenario: Forge agent reaches enclave service through proxy
- **WHEN** an agent inside a forge container runs
  `curl http://my-project.flutter.localhost/`
- **THEN** the request SHALL go to `proxy:3128` (forward proxy)
- **AND** Squid SHALL forward the request to `router:80` (reverse
  proxy peer)
- **AND** the router SHALL route to the right container at the right
  internal port
- **AND** the agent SHALL receive the dev server's response

#### Scenario: External `.localhost` resolution attempt is denied
- **WHEN** Squid receives a `.localhost` request and the router peer
  is unreachable
- **THEN** Squid SHALL return an error response, NOT fall through to
  external DNS resolution
- **AND** no `*.localhost` lookup SHALL ever leave the host
