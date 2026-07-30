# Proxy & Git Mirror Configuration Audit (REDUCED)

**Date:** 2026-07-09 (reduced 2026-07-30)
**Classification:** audit
**Order:** 247
**Host:** linux-forge-arch-audit-20260730
**Reduction engine:** Every finding ends as either (a) a new `ready` packet in
plan/index.yaml with a named verifiable closure, or (b) an explicit note that
it is already covered, citing the packet id. Prose-only findings do not close;
this file replaces the 2026-07-09 original which produced 5 prose deliverables
without a single reduction.

---

## Finding 247-A: containers.conf [engine] env proxy poisons ALL host podman operations

**Observation:** `tillandsias --init` writes `HTTP_PROXY=http://proxy:3128` into
the user's global `~/.config/containers/containers.conf` under `[engine] env`
(main.rs:5519-5559). Podman applies `[engine] env` to its OWN host-side registry
client, not only to launched containers. With the enclave down, every host
`podman pull` fails — `proxy` only resolves inside the enclave network. Affects
`podman build`, `podman pull`, and `toolbox create`.

**Reduction: already-covered**
- Packet: `podman-build-proxy-injection-blocks-local-image-builds` (order 517)
- Status: `ready` in plan/index.yaml:24871-24931
- Root cause documented with 3-surface scope (build, pull, toolbox create)
- The no_proxy gap (missing external registries) is explicitly noted in
  order 517's progress event (plan/index.yaml:24904)
- Exit criteria: fix or document + named error + litmus
- **Verified by reading:** order 517 exit criteria (lines 24895-24897) are
  complete and correctly capture the three fix dimensions. No gap found.

**Fix direction confirmed per established evidence:** An identical pull succeeds
with a `CONTAINERS_CONF` that omits the `[engine]` env block. The canonical fix
is to either (a) scope proxy injection to per-container `--env` rather than
global engine config, or (b) extend the `no_proxy` list to include every
registry the product pulls from (docker.io, quay.io,
registry.fedoraproject.org, ghcr.io). Option (a) is cleaner and avoids unbounded
maintenance of a registry allowlist. Option (b) is fragile (new registries
require updating the list). **Recommendation: option (a).**

---

## Finding 247-B: Unbounded registries.conf backup accumulation — fixed

**Observation:** `scripts/setup-podman-registries.sh` had accumulated 989
byte-identical `registries.conf.backup.<epoch>` files (3.9 MB) in
`~/.config/containers` by 2026-07-29.

**Reduction: already-covered (fix committed)**
- The fix is committed in `scripts/setup-podman-registries.sh`:44-71
- Script is now idempotent (`cmp -s` check before write)
- Keeps exactly ONE rollback copy (`.prev`) when content changes
- Includes cleanup loop that prunes legacy identical backups
- **Unbounded-artifact sweep:** checked every script in the proxy/mirror config
  path for the same pattern:
  - `scripts/install-macos.sh:124` — uses single `.bak` (intentional, not unbounded)
  - No other script in the proxy/mirror path accumulates artifacts
- No new packet needed

---

## Finding 247-C: No end-to-end proxy health litmus

**Observation:** A shape litmus exists at
`openspec/litmus-tests/litmus-proxy-container-shape.yaml` (169 lines) — it pins
source surfaces (Containerfile, squid.conf, allowlist.txt, entrypoint.sh) but
has NO runtime health assertion. There is no automated check that the running
proxy actually:
  - Accepts HTTPS CONNECT tunnels
  - Intercepts TLS with the correct CA cert
  - Enforces the domain allowlist
  - Respects HTTP/HTTPS dual-port architecture

**Reduction: new ready packet**
- Packet: `proxy-end-to-end-health-litmus`
- Order: 530
- Verifiable closure: A litmus test (yaml + shell) that, when run against the
  built proxy container, exits 0 when the full proxy stack is verified:
  1. Proxy container starts and listens on ports 3128 and 3129
  2. DNS resolution through proxy succeeds (HTTP CONNECT to known domain)
  3. TLS interception uses the enclave intermediate CA (cert fingerprint check)
  4. Allowlist correctly permits `github.com` and blocks an unlisted domain
  5. Non-TLS HTTP proxy on port 3129 does NOT use ssl-bump
- Added to plan/index.yaml as ready packet order 530

---

## Finding 247-D: Existing audit issue was unreduced prose (this file replaces it)

**Observation:** The 2026-07-09 original of this file contained 5 prose
deliverables (proxy configuration inventory, TLS cert chain audit, git mirror
forwarding, proxy health litmus, spec/cheatsheet patch list) — none reduced to
a verifiable closure.

**Reduction: resolved by audit**
- Deliverable 1 (proxy config inventory): covered by findings 247-A, 247-B, 247-C
- Deliverable 2 (TLS cert chain audit): overlaps with order 246
  (credential-secrets-architecture-audit); cross-reference there
- Deliverable 3 (git mirror forwarding): see existing packets
  `git-mirror-upstream-forwarding` (order 167) and
  `blocker-git-mirror-push-receive-pack-disabled-2026-07-20.md`
- Deliverable 4 (proxy health litmus): new packet order 530 (finding 247-C)
- Deliverable 5 (spec/cheatsheet patch list): overlaps with order 248
  (spec-cheatsheet-contradiction-audit); cross-reference there
- The unreduced issue has been replaced by this REDUCED version

---

## Finding 247-E: CA trust anchor propagation gap in forge containers (overlaps order 246)

**Observation:** The forge container mounts the enclave CA at
`/run/tillandsias/ca-chain.crt` and `lib-common.sh` composes a bundle at
`/run/tillandsias/ca-bundle.crt`, but **never exports `SSL_CERT_FILE`** for Go
binaries. `NODE_USE_SYSTEM_CA=1` helps Node.js, but Go's `crypto/x509` reads
`SSL_CERT_FILE`, not the system trust store. The inference container had the
same defect (order 525). Same pattern in the git container: `GIT_SSL_CAINFO` is
set for git operations but `SSL_CERT_FILE` is absent for the `gh` CLI (Go).

**Reduction: cross-reference to order 246**
- This is a credential-secrets-proxy boundary finding
- `images/default/lib-common.sh:18-57` — `init_runtime_ca_trust` must also
  export `SSL_CERT_FILE` and `CURL_CA_BUNDLE`
- `images/git/entrypoint.sh:76-84` — missing `SSL_CERT_FILE` for Go binaries
- **To avoid double-filing:** order 246 (credential-secrets-architecture-audit)
  should verify and reduce this finding. If order 246 does not cover it, a new
  packet `proxy-ca-trust-propagate-to-containers` should be created.
- This audit has verified the scope: the proxy CA is correctly mounted into
  every container (launcher bind-mounts are correct), but the ENV VAR
  propagation for Go binary consumers is incomplete. The trust-anchor-vs-consumer
  mismatch pattern matches the inference container's pre-order-525 state.

---

## Summary of Verification

| Finding | Reduction | Status |
|---|---|---|
| 247-A: containers.conf poisons host podman | → order 517 (ready) | Verified |
| 247-B: unbounded registries.conf backups | → already fixed | Verified |
| 247-C: no proxy health litmus | → NEW packet order 530 | Filed |
| 247-D: unreduced original issue | → replaced by this file | Done |
| 247-E: CA trust gap in forge/git containers | → cross-ref order 246 | Outstanding |

## Verifiable Closures Created

1. **order 530 `proxy-end-to-end-health-litmus`** — A litmus that exits 0 when
   the running proxy passes DNS+CONNECT+TLS+allowlist+dual-port checks. The
   litmus YAML is the named verifiable closure. A `ready` packet filed in
   plan/index.yaml.
