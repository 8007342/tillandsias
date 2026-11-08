## Context

- **Today's proxy** (`images/proxy/squid.conf`):
  - port 3128 is strict: `dstdomain` allowlist, peek at step 1, bump only
    GitHub release assets, splice everything else;
  - port 3129 is for builds and allows all.
- **Proxy wiring:** containers get `HTTP(S)_PROXY=http://proxy:3128` from
  `main.rs` and `remote_projects.rs`.
- **The allowlist** is sectioned: registries, CDNs, toolchains, VCS, cloud
  SDKs, AI/ML, AI search, code analysis, docs, certificates, container/OS, and
  the project's own site.
- **The studio registry** (`data/studios.json`, built by
  `build-studio-registry.lua`) carries `kind` (forge or sibling) and an image.
  It has no egress field.

Research: other harnesses close the shell's egress and serve fetch/search
from a separate tool, with Markdown conversion, caps and a private-IP refusal.
Squid can decide on SNI and splice. Podman `--internal` networks give the
`none` and `siblings` tiers with no firewall rules.

## Decisions

### 1. The tier ladder (composable, not ordered)

| Tier | Reach | Enforced by |
|---|---|---|
| `none` | nothing | no network, or an `--internal` network with no proxy |
| `siblings` | named enclave containers | `--internal` enclave network; aardvark-dns resolves only container names |
| `host` | named host services (the tray control socket, host inference) | explicit host-gateway entry for the named ports only |
| `registries` | package registries and toolchains (allowlist sections: package registries, language tools, container/OS, security/certificates) | proxy port for the tier set |
| `assets` | fonts and CDNs (googleapis/gstatic fonts, jsdelivr, unpkg, esm.sh, cdnjs) | proxy |
| `providers` | model APIs the harness uses (anthropic, openai, opencode, …) | proxy |
| `model-hubs` | huggingface, ollama | proxy |
| `vcs` | git hosts | proxy (the git mirror only) |
| `research` | docs and web, read-only | the fetch service, never the proxy |

### 2. Container → tier map (defaults)

| Container | Tiers |
|---|---|
| vault | `none`, plus the siblings that call it |
| router | `siblings` |
| git mirror | `siblings`, `vcs` |
| inference | `siblings`, `model-hubs` (fetch only) |
| forge | `siblings`, `registries`, `assets`, `providers`, `research` (via MCP) |
| imagegen studio / ComfyUI | `siblings`, `model-hubs`, `assets` |
| web studios and wranglers | `siblings`, `assets` |
| chromium (browser) | unchanged (`browser-routing-allowlist`) |
| fetch service | its catalog plus search-result URLs, via the proxy's `research` port |
| proxy | upstream |

### 3. Enforcement

- **One Squid port per declared tier set**, matched with `myportname`.
  Distinct sets are few, so this is a handful of ports, generated at proxy
  start from the tier files.
- **Match on `ssl::server_name`.** Splice by default and keep the existing
  narrow bump for release assets.
- **Check the destination.** Squid connects to the SNI's resolution, and a
  CONNECT whose target IP differs from the SNI's resolution is refused (the
  research flagged SNI spoofing).
- **Each container's proxy URL comes from its declaration.** A container that
  declares no proxied tier gets no proxy env and an internal network, so it
  fails closed.
- **Per-port `delay_pools`, and an access log** with SNI, port (tier) and
  client.

### 4. Declaration

- **Images:** `images/<image>/egress.yaml`, holding `tiers: [...]` and an
  optional `extra:` list of named domains, each with a `reason`.
- **Studios:** `data/studios.json` entries carry `egress`, and
  `build-studio-registry.lua` refuses an entry without it, as it does for
  `good_for`.
- **Other projects:** a generic project declares tiers in its own
  `.tillandsias/egress.yaml`.
- **Launch:** headless reads the declaration at launch. A litmus check refuses
  any image directory that has no `egress.yaml`.

### 5. The fetch/search service (`enclave-fetch`, MCP)

- **Its own container:** on `siblings`, plus the proxy's `research` port.
- **Tools:**
  - `search(query)`: through a configured search API. The key is read from
    Vault and never enters a forge.
  - `fetch(url)`: HTML to Markdown, capped length with paging.
  - `feed(name)`: RSS/Atom from the catalog.
  - `docs(library, query)`.
- **What it may fetch:** the curated catalog, plus any URL returned by a search
  in the same session (bounded, expiring). Anything else is denied and queued
  for approval.
- **Safeguards:**
  - refuses private, loopback and metadata IPs after resolving, and pins the
    connection to that IP;
  - obeys robots.txt;
  - sends no cookies or credentials;
  - rate limits per client;
  - writes a JSONL audit log (client, tool, URL, bytes, verdict).
- **The catalog:** a versioned file, one entry per source, each carrying
  `url`, `kind`, `reason` and `provenance`.

### 6. Scaling without hand curation

- **Package traffic moves to sibling mirrors** (Verdaccio, Athens, devpi or a
  pull-through cache) where they exist, so `registries` shrinks to their
  upstreams.
- **Search results are fetchable by construction.**
- **Unknown names are denied and queued.** The tray shows "<container> asked
  for <host>"; the operator approves for one session or adds it to a tier
  permanently. A permanent approval is written as a catalog or tier entry with
  provenance (who, when, why). Nothing is ever auto-allowed.

### 7. Migration

1. **Split** allowlist.txt into `images/proxy/tiers/<tier>.txt` along its
   sections. A litmus check pins that the union equals the old file.
2. **Generate per-tier ports.** Port 3128 keeps serving the union.
3. **Declare** `egress.yaml` for every image and studio. Containers move to
   their tier port one at a time.
4. **Ship `enclave-fetch`** and wire it into the forge's MCP config. This
   closes 2037-4ptq.
5. **Retire the 3128 union** once no container uses it.

## Risks

- Too-narrow tiers break builds at first. Mitigation: the union port keeps
  working until each container's cut-over, and the approval queue makes every
  miss visible.
- A summarising or Markdown step lowers prompt-injection risk but does not
  remove it. Fetched content stays untrusted data.
- More Squid ports mean more config. They are generated from the tier files,
  never hand-written.
