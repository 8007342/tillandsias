---
tags: [git, git-mirror, credentials, proxy, forge, architecture, audit]
languages: [bash, rust]
since: 2026-07-12
last_verified: 2026-07-14
sources:
  - images/git/entrypoint.sh
  - images/git/post-receive-hook.sh
  - images/git/pre-receive-hook.sh
  - images/git/vault-cli.sh
  - images/default/lib-common.sh
  - crates/tillandsias-headless/src/main.rs
  - scripts/check-credential-channel.sh
  - plan/issues/git-mirror-push-false-success-not-relayed-2026-07-12.md
  - plan/issues/forge-mirror-insteadof-missing-2026-07-12.md
  - plan/issues/git-mirror-fetch-clobbers-exported-ref-2026-07-12.md
  - plan/issues/mirror-pre-receive-openspec-yaml-reject-2026-07-12.md
  - plan/issues/forge-credential-guard-push-channel-gap-2026-07-08.md
  - plan/issues/git-mirror-architecture-audit-2026-07-12.md
authority: high
status: current
tier: bundled
summary_generated_by: "claude-fable-5 order-315 audit"
bundled_into_image: true
committed_for_project: true
---
# Git-Mirror Architecture Audit — Current State Map (order 315)

All file:line references were refreshed against linux-next `6a5af9a2`
(2026-07-14). Every
claim below was verified in the tree during this audit; claims sourced from
plan issues cite the issue file.

## 1. Topology (designed)

```
forge container ──git:// (9418) / http (8080)──► tillandsias-git container ──https+token──► GitHub
     ▲                                                    ▲
     │ zero credentials by design                         │ GitHub token read at push time
     │ insteadOf rewrite → mirror                         │ from Vault (AppRole token secret)
```

- Mirror container launch: `build_git_run_args` (crates/tillandsias-headless/src/main.rs:2273-2349).
  Aliases `git-service` + `tillandsias-git`; bare repos on named volume
  `tillandsias-mirror-<project>` at `/srv/git`; `--read-only`,
  `--cap-drop=ALL`, `--userns=keep-id`, pids 64.
- Serving: `git daemon --export-all --enable=receive-pack` :9418 + lighttpd
  smart-HTTP :8080 (images/git/entrypoint.sh:196-209).
- Upstream URL arrives as env `TILLANDSIAS_PROJECT_REMOTE_URL` (main.rs:2317-2322
  → entrypoint.sh:72-92).
- Upstream credential: podman secret → `/run/secrets/vault-token`
  (`GIT_VAULT_TOKEN_SECRET_OPTS` main.rs:2259-2260, uid=1000 mode=0400);
  the pre-receive relay reads `vault-cli read -field=token
  secret/github/token` at push time. No token rejects an HTTPS push before
  Git can prompt or the mirror can update its local refs.

## 2. Ack/relay semantics (the P1)

| Stage | Behavior | Provenance |
|---|---|---|
| pre-receive | validates ledger YAML, then relays the complete proposed ref set upstream with `git push --atomic` | pre-receive-hook.sh + relay-refs.sh |
| relay failure | pre-receive exits non-zero; neither the local nor upstream ref transaction partially updates | scripts/test-git-mirror-relay-verified-ack.sh |
| local accept | occurs only after configured-upstream acceptance; no-origin projects are explicitly durable local-only | pre-receive-hook.sh + post-receive-hook.sh |
| post-receive | bookkeeping only; never establishes relay success | post-receive-hook.sh |
| startup retry | synthesizes receive records and reuses the Vault-backed atomic relay helper | entrypoint.sh |

**Finding A (fixed and pinned):** order 318 moved must-succeed relay out of
post-receive and into pre-receive. The helper forwards one atomic transaction
of explicit SHA refspecs, and receive-pack rejects the forge push if an HTTPS
credential is absent or the upstream rejects any member. The offline fixture
proves missing-credential failure, successful convergence with strict upstream
`fsck`, and all-or-nothing multi-ref rejection. Post-receive now records only
the already-decided local transaction.

**Finding B (fixed and pinned):** order 316 removed the lost pipeline state;
the current POSIX loop writes a failure marker that the parent checks before
relay, so the final `exit 1` is effective. `scripts/test-pre-receive-yaml-gate.sh`
proves an invalid update is rejected, a valid update is accepted, and a mixed
multi-ref push is rejected. Order 336 made the fixture use the production Rust
`tillandsias-policy` parser, removing the divergent PyYAML wrapper.

**Finding C (fixed and deployed):** order 301 replaced the clobbering
`+refs/*:refs/*` reconcile with the safe
`+refs/heads/*:refs/remotes/origin/*` refspec and retained explicit per-ref
pushes. Order 302 rebuilt and installed the image, then verified that a
fresh mirror container carried the corrected entrypoint and preserved an
exported ref across reconcile.

## 3. Config injection into forges — per platform

| Mechanism | Linux podman (tray/CLI) | macOS VM forge | Windows/WSL |
|---|---|---|---|
| `write_forge_gitconfig` file (safe.directory, http.sslCAInfo=/etc/tillandsias/ca.crt, credential.helper=, core.hooksPath, insteadOf) bind-mounted RO at `/home/forge/.config/git/config` + `GIT_CONFIG_GLOBAL` | YES (main.rs:5379-5436, mounted at main.rs:7696-7702) | **NO equivalent observed** — macOS forge had bare GitHub origin, agent hand-hacked `.git/config` (plan/issues/forge-mirror-insteadof-missing-2026-07-12.md) | n/a (filesystem transport does repo-local insteadOf) |
| `rewrite_origin_for_enclave_push` (entrypoint runtime, `git config --global` insteadOf; only fires when `TILLANDSIAS_PROJECT_HOST_MOUNT=1` and origin is GitHub) | YES, host-mount lane (lib-common.sh:290-383) | not reached if HOST_MOUNT unset (lib-common.sh:321) | not reached |
| `clone_project_from_mirror` network transport: origin=`git://tillandsias-git/<p>`, push-url forced to mirror | YES (lib-common.sh:487-511) | intended, but see divergence below | — |
| filesystem transport: clone from `TILLANDSIAS_GIT_MIRROR_PATH`, cosmetic GitHub origin + repo-LOCAL insteadOf | — | — | YES (lib-common.sh:436-482) |
| tmpfs quarantine of ~/.ssh, ~/.config/gh (order 170) | YES (main.rs:7658-7659) | unverified | unverified |

**Finding D (host↔forge bidirectional leak, verified by evidence chain):**
the Linux host-mount lane bind-mounts the host checkout RW
(main.rs:7621-7625), so the forge's repo-local `git config` writes land in
the HOST's `.git/config`. All Tillandsias-owned code carefully writes
`--global` only (lib-common.sh:355-380 comments), but any AGENT inside the
forge can (and on macOS did) write `.git/config` directly — poisoning the
host (osx-next 258327d6 "insteadOf host-poisoning addendum"). Conversely the
host's `.git/config` (origin URL, hooks, helpers) flows INTO the forge. The
quarantine covers `~/.ssh`/`~/.config/gh` but NOT the project `.git/`.

## 4. Env-var inventory crossing runtime boundaries

Producers: `build_forge_agent_run_args` (main.rs:7602-7724), `apply_proxy_env`/
`proxy_env_args` (main.rs:856-905), `build_git_run_args` (main.rs:2273-2349),
CA blocks in every entrypoint (e.g. entrypoint-forge-opencode.sh:44-68) and
lib-common.sh:15-33.

| Var | Set by | Consumed by | Runtime notes |
|---|---|---|---|
| GIT_CONFIG_GLOBAL | podman env (main.rs:7660) | git in forge | Linux lanes only; forge dev hosts' global hooksPath shadowing bit order-301 fixture (plan/issues/optimization/forge-global-hookspath-shadows-repo-hooks-2026-07-12.md) |
| GIT_SSL_CAINFO | entrypoints (added 9d04c99f); mirror entrypoint.sh:39-43 | git/libcurl | exists because injected gitconfig pins enclave-CA-only http.sslCAInfo |
| SSL_CERT_FILE / REQUESTS_CA_BUNDLE | entrypoint CA blocks; lib-common.sh:25-27 | OpenSSL tools, curl, pip | duplicated logic in 7 files (6 entrypoints + lib-common), two variable names (COMBINED vs COMBINED_CA) |
| NODE_EXTRA_CA_CERTS | podman env (main.rs:7680) | Node/undici | separate from OpenSSL trust |
| HTTP(S)_PROXY / NO_PROXY (+lowercase) | proxy_env_args (main.rs:864-889) | curl/git/node in enclave containers | 3 P0s from missing exemptions (memory: enclave-proxy-exemption-pattern) |
| GH_TOKEN / GITHUB_TOKEN | host env only | check-credential-channel.sh:52-59; gh | never injected into forges (by design) |
| TILLANDSIAS_HOST_KIND=forge | every entrypoint | credential guard forge branch | guard now live-probes mirror (scripts/check-credential-channel.sh:66-104) |
| TILLANDSIAS_PROJECT / _HOST_MOUNT / _GIT_SERVICE / _GIT_MIRROR_PATH / _PROJECT_REMOTE_URL | launcher per lane | lib-common clone/rewrite; mirror entrypoint | transport selection is implicit in which var is set — three-way branching (lib-common.sh:403-516) |
| GIT_AUTHOR/COMMITTER_* pairs | git_identity_env_pairs (main.rs:5314) | git in forge | identity without touching config files |
| VAULT_ADDR / VAULT_ROLE / CURL_CA_BUNDLE | build_git_run_args (main.rs:2332-2337) | vault-cli in mirror | mirror-only |

Count: ~20 vars spanning 4 trust domains (host, VM guest, enclave containers,
forge). The operator's "polluted and incompatible" verdict maps to: 7-file CA
duplication, transport-by-env-presence, per-tool CA vars (git vs OpenSSL vs
Node vs Requests), and platform-divergent injection (§3).

## 5. Credential surfaces & the guard

Ladder (scripts/check-credential-channel.sh:44-108): `.git/.gh-credentials`
→ `GH_TOKEN` → `GITHUB_TOKEN` → `gh auth status` → forge branch. The forge
branch no longer trusts `TILLANDSIAS_HOST_KIND` alone: it requires effective
origin to resolve to the mirror AND a live `git ls-remote` through it
(:66-104). Reachability remains a read-channel probe, but it is no longer
used as proof of relay: the write operation itself now returns non-zero until
the configured upstream atomically accepts it. GitHub token storage remains
Vault `secret/github/token`, written by GitHub Login and read only inside the
mirror at relay time.

## 6. Hack inventory → DEFAULTS OVER CONFIGURATION dispositions

| Mechanism | Why it exists | Breaks if removed | Git-native candidate | Disposition |
|---|---|---|---|---|
| insteadOf rewrites (3 variants: image-injected global, runtime global, repo-local) | route GitHub URLs to mirror without touching host config | forge pushes hit GitHub w/o creds | ONE canonical remote: clone from mirror with origin=mirror; present upstream as separate `upstream` remote, or keep exactly one injected-gitconfig insteadOf | replace-with-default (single injection point, all platforms) |
| pre-receive atomic relay | make client success mean configured-upstream durability | false-success data loss returns if removed | keep synchronous `git push --atomic` with explicit refspecs; post-receive remains bookkeeping only | keep-justified (order 318 fixture) |
| token-in-URL `https://oauth2:TOKEN@` built in-shell | no credential helper in Alpine image | relay auth | `git credential` helper (`credential.helper` invoking vault-cli via the documented git-credential protocol); token never in argv/URL | replace-with-default |
| `http.sslCAInfo` enclave-CA-only + GIT_SSL_CAINFO combined-bundle band-aid | proxy MITM trust | git TLS through proxy | install combined CA at the DISTRO default path at image build (update-ca-certificates) → zero TLS env vars for every tool | replace-with-default |
| CA-block duplication in 6 entrypoints + lib-common | historical copy-paste | drift (already: COMBINED vs COMBINED_CA) | single lib-common function; better: image-baked trust store | delete-candidate (after trust-store fix) |
| transport selection by env-var presence | Windows lacks git daemon | wrong-transport confusion | one explicit `TILLANDSIAS_GIT_TRANSPORT={mirror-daemon,mirror-path,host-mount}` or derive from a single mirror URL | replace (1 var instead of 4) |
| `denyNonFastforwards=false` on mirror | initial host sync looks like force-push | first push rejected | seed mirror from upstream at init (entrypoint already fetches); then default `denyNonFastforwards=true` restores git's own safety | replace-with-default |
| credential guard forge branch trusting reachability | pre-push verifiability | none (it under-verifies today) | mirror exposes relay state (e.g. `refs/notes/relay` or status file over HTTP :8080); guard checks it | replace (pairs with ack fix) |
| tmpfs quarantines ~/.ssh, ~/.config/gh | host cred leak via source mount | cred leakage | keep — cheap, effective | keep-justified |
| pre-receive YAML gate | protect shared ledger | broken YAML reaches GitHub | fix subshell + `safe_load permitted_classes: [Date]`; keep as real gate | keep (after Finding B fix) |
| explicit per-ref refspecs everywhere (never `--mirror`) | `--mirror` nearly wiped upstream (wave 24) | catastrophic ref deletion | keep — this IS the enterprise practice for sparse mirrors | keep-justified |

### Explicit environment-variable dispositions

These rows close the inventory mechanically: every variable named in section
4 has exactly one disposition and no unresolved category. A
`replace-with-default` row describes the migration target; its child packet
remains responsible for implementation and removal.

| Variable | Disposition | Default or retained contract |
|---|---|---|
| `GIT_CONFIG_GLOBAL` | replace-with-default | Install one standard read-only `~/.gitconfig`/include path in every forge lane; stop redirecting Git with an environment variable. |
| `GIT_SSL_CAINFO` | replace-with-default | Install the combined trust chain in the image's system trust store so Git/libcurl uses its distro default. |
| `SSL_CERT_FILE` | replace-with-default | Use the image's system trust store rather than an entrypoint-generated bundle path. |
| `REQUESTS_CA_BUNDLE` | replace-with-default | Use the image's system trust store rather than an entrypoint-generated bundle path. |
| `NODE_EXTRA_CA_CERTS` | replace-with-default | Install proxy trust in the image and enable Node's system-CA behavior in the image, pinned by a Node TLS litmus before removal. |
| `HTTP_PROXY` | keep-justified | Standard proxy interface required while the allowlisted enclave proxy remains the egress boundary. |
| `HTTPS_PROXY` | keep-justified | Standard proxy interface required while the allowlisted enclave proxy remains the egress boundary. |
| `NO_PROXY` | keep-justified | Standard proxy bypass interface for canonical enclave-local services. |
| `http_proxy` | keep-justified | Compatibility form for clients that only honor lowercase proxy variables; remove only after a client-matrix litmus. |
| `https_proxy` | keep-justified | Compatibility form for clients that only honor lowercase proxy variables; remove only after a client-matrix litmus. |
| `no_proxy` | keep-justified | Compatibility form for clients that only honor lowercase proxy variables; remove only after a client-matrix litmus. |
| `GH_TOKEN` | keep-justified | Standard host-only `gh` credential input and guard signal; it must never be injected into a forge. |
| `GITHUB_TOKEN` | keep-justified | Standard host-only compatibility credential input and guard signal; it must never be injected into a forge. |
| `TILLANDSIAS_HOST_KIND` | delete | Replace the forge guard branch with verified mirror/relay state; a self-declared host kind is not a security fact. |
| `TILLANDSIAS_PROJECT` | replace-with-default | Derive the project from the working directory or one canonical project descriptor instead of a process-wide variable. |
| `TILLANDSIAS_PROJECT_HOST_MOUNT` | delete | Make the selected mount/transport spec authoritative; do not infer topology from a boolean environment flag. |
| `TILLANDSIAS_GIT_SERVICE` | replace-with-default | Pass one canonical mirror URL through the transport descriptor or Git remote. |
| `TILLANDSIAS_GIT_MIRROR_PATH` | replace-with-default | Pass one canonical mirror URL through the transport descriptor or Git remote. |
| `TILLANDSIAS_PROJECT_REMOTE_URL` | replace-with-default | Persist the clean upstream as the bare repository's `origin` during mirror creation instead of exposing it to every process. |
| `GIT_AUTHOR_NAME` | keep-justified | Standard Git non-secret identity interface; avoids mutating shared configuration. |
| `GIT_AUTHOR_EMAIL` | keep-justified | Standard Git non-secret identity interface; avoids mutating shared configuration. |
| `GIT_COMMITTER_NAME` | keep-justified | Standard Git non-secret identity interface; avoids mutating shared configuration. |
| `GIT_COMMITTER_EMAIL` | keep-justified | Standard Git non-secret identity interface; avoids mutating shared configuration. |
| `VAULT_ADDR` | keep-justified | Standard Vault client endpoint, scoped to the mirror container. |
| `VAULT_ROLE` | delete | The current baked `vault-cli` consumes the mounted token and `VAULT_ADDR`; it never reads this launcher-only label. |
| `CURL_CA_BUNDLE` | replace-with-default | Install the combined trust chain in the image's system trust store so curl uses its distro default. |

## Open questions (not fully verifiable from the tree)

1. Which transport/lane produced the macOS forge with a DIRECT GitHub origin
   (forge-mirror-insteadof-missing): host-mount without
   `TILLANDSIAS_PROJECT_HOST_MOUNT=1` propagated, or a remote-projects clone
   path outside `clone_project_from_mirror`? Needs a live macOS repro trace.
2. Whether the macOS guest mirror container receives the vault-token secret
   at all (the false-success P1's credential hypothesis) — requires in-guest
   `podman inspect tillandsias-git-<p>`.
3. Whether Windows/WSL bare-mirror hooks execute with vault-cli available
   (post-receive-hook.sh:15-19 says hooks run in the forge distro context —
   token path there is unclear).
