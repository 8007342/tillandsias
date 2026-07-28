# Local HTTPS: Apache in the enclave serves the developer's project with enclave-CA-minted certs, trusted transparently by forge + browser (2026-07-24)

- **Date**: 2026-07-24
- **Class**: research+impl (topology/chain decisions gate the impl rungs)
- **Area**: enclave web serving / CA trust / web-share family (plan/index.yaml orders 373-381)
- **Severity**: enhancement (v0.5 direction; nothing broken today — the gap is fidelity)
- **Owner**: linux
- **Discovered-by**: operator directive (The Tlatoani, 2026-07-24)
- **Status**: proposed
- **Desired release**: v0.5
- **Cross-ref (rides it, does not duplicate it)**: `plan/issues/research-cert-lifecycle-state-graph-2026-07-24.md` — hostname scheme, cert minting, and rotation are NODES in that state graph; this packet contributes the web-leaf node, not a second lifecycle.
- **Relates_to**: `plan/issues/forge-trust-ca-source-readiness-gap-2026-07-23.md` (the forge-side CA readiness this packet's transparency leans on)

## Operator rationale (near-verbatim, 2026-07-24)

For local development many libraries refuse to load, or emit CORS warnings, without real
HTTPS. The only way to properly reproduce a real working environment is real HTTPS serving
locally. "It runs on my machine" takes on a whole new level when "my machine" is a portable
cloud — now "it also runs on the cloud."

## Today's state (file:line evidence)

The web-share family is plain HTTP end to end:

- `images/web/entrypoint.sh:17` — the web container is busybox `httpd -f -p 8080`; the live
  publish evidence URL is `http://www.visual-chess.localhost:8080` (plan/index.yaml order-374
  progress event, 2026-07-16T03:20Z). No TLS anywhere on the serving path.
- `images/router/base.Caddyfile:18-21` — the Caddy router explicitly sets `auto_https off`,
  plain HTTP `:8080`; host publish is loopback-only (`images/router/Containerfile:20-22,95`).
- `images/proxy/squid.conf:57-59,127-130` — `.localhost` requests are forwarded to the router
  via `cache_peer router parent 8080`, `never_direct` — the in-enclave path a leaf must cover.

The enclave CA already exists, and forge trust already folds it in transparently:

- `crates/tillandsias-headless/src/main.rs:2108` — `ensure_ca_bundle` mints a single
  self-signed RSA-2048 `CN=Tillandsias CA`, 30-day validity (`main.rs:2172-2191`), atomically
  published to `CA_DIR=/tmp/tillandsias-ca` (`main.rs:1022`).
- `crates/tillandsias-headless/src/main.rs:2415-2421` — squid gets it bind-mounted at
  `/etc/squid/certs/intermediate.{crt,key}` and mints ssl-bump leaves via sslcrtd
  (`images/proxy/squid.conf:12-14,27-28`) — but ONLY for bumped upstream hosts
  (`squid.conf:78-79`). There is NO leaf-minting path for services WE serve.
- `images/default/lib-common.sh:34-47` — every forge composes its runtime trust bundle from
  vendor roots + the mounted `/run/tillandsias/ca-chain.crt` (mount at `main.rs:4743-4747`),
  so a forge trusts ANY leaf chained to the enclave CA with zero per-container work.
- Host-browser trust does NOT exist: no `update-ca-trust`/`certutil`/trust-anchor call sites
  anywhere in `crates/` (grep, 2026-07-24).
- `openspec/specs/certificate-authority/spec.md:6` is an obsolete tombstone; live CA contracts
  are in `reverse-proxy-internal` — new requirements land there or in a new spec, never the
  tombstone. `openspec/specs/enclave-network/spec.md:10` — only the proxy is dual-homed.

## Proposal shape

1. **`images/apache`**: real Apache httpd (mod_ssl) joins the enclave stack as an
   enclave-internal member (never dual-homed), serving the developer's project (ro mount,
   same share rules as `images/web` / order 361-376 family) over HTTPS with a leaf cert.
2. **Leaf minting**: a host-side seam beside `ensure_ca_bundle` mints a per-hostname leaf
   (SAN: `www.<project>.localhost`, `<project>.localhost`) signed by the enclave CA and
   bind-mounts it like squid's cert mount (`main.rs:2415-2421` pattern). Mint, re-mint on
   the 30-day CA rotation (`main.rs:2186-2187`), and revocation are nodes in the
   cert-lifecycle state graph (cross-ref) — no bespoke rotation loop here.
3. **Routing**: `https://www.<project>.localhost` reaches apache. Termination topology is
   the research decision: (A) SNI passthrough at the router, apache terminates; (B) Caddy
   terminates with a minted leaf, apache serves behind; (C) dedicated https loopback publish.
4. **Trust**: forge — free via the `lib-common.sh` fold; host browser — explicit, scripted,
   revocable opt-in (`update-ca-trust` system store / `certutil` NSS user db), never silent.

## Investigate first

- Which libraries/browsers actually refuse or warn on `http://*.localhost` (secure-context
  rules) — reproduce and record the concrete failures the operator names; they are the
  fidelity bar the e2e must clear.
- Topology A/B/C above: interaction with the squid `cache_peer` path (`squid.conf:127-130`),
  CONNECT handling for in-enclave https, and whether the forge reaches apache direct-by-name
  or through the proxy (enclave-proxy exemption lessons, order 378 outcome).
- Chain shape: today's "intermediate" is really a self-signed root. Installing a 30-day
  rotating root into a browser store is UX-hostile — likely a longer-lived local root signing
  the rotating operational CA. This is a cert-lifecycle-graph decision; file the node there.
- SELinux labels for the new cert mounts (the login-container `relabel=shared` lesson,
  `main.rs:16740` test pin) and 0600/0644 split for leaf key vs cert.

## Exit criteria (each backed by a verifiable constraint)

1. **Shape litmus (instant, pre-build)**: `images/apache/` exists (Containerfile +
   entrypoint), enables mod_ssl, references leaf paths under `/etc/tillandsias/certs/`, and
   embeds NO cert/key material (`grep -RL 'BEGIN \(CERTIFICATE\|PRIVATE KEY\)'` clean).
2. **Chain check (executable)**: minted leaf verifies — `openssl verify -CAfile
   $CA_DIR/intermediate.crt <leaf>` exits 0 and `openssl x509 -checkhost
   www.<project>.localhost` matches the SAN.
3. **E2E (local-build gate)**: from inside the enclave, `curl --cacert intermediate.crt
   https://www.<project>.localhost/` returns HTTP 200 with the project's index via the
   routed path.
4. **Forge transparency e2e**: an in-forge `curl https://www.<project>.localhost/` succeeds
   with NO `--cacert`/`--insecure` — proving the `lib-common.sh:34` trust fold covers our
   own minted leaves, not just bumped upstreams.
5. **Host trust scripts (executable, idempotent, opt-in)**: after install, `trust list`
   (or `certutil -L`) shows the Tillandsias anchor; after uninstall it does not; both
   asserted by an executable check that runs twice without error.
6. **Single lifecycle authority (grep litmus)**: exactly one leaf-mint invocation site in
   `crates/`, reached through the cert-lifecycle seam (grep count == 1) — no parallel
   openssl rotation loop.

## Non-goals / scope

- NOT the public share path — `https` on the operator domain is orders 378-379 (cloudflare
  tunnel terminates that TLS); this packet is the LOCAL fidelity rung those build on.
- NOT replacing plain-http `publish_local` as default — coexistence until the topology
  decision says otherwise.
- NOT fixing the forge CA-source readiness gap (its own packet, relates_to above) — but
  exit criterion 4 will surface regressions in it.
- NOT resurrecting the `certificate-authority` tombstone spec; requirements land in
  `reverse-proxy-internal` or a new `local-https-serving` spec.
