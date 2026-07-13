---
tags: [git, git-mirror, credentials, proxy, forge, architecture, audit]
languages: [bash, rust]
since: 2026-07-12
last_verified: 2026-07-12
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

All file:line references are as of linux-next `8875ba82` (2026-07-13). Every
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
  post-receive reads `vault-cli read -field=token secret/github/token` at
  push time (post-receive-hook.sh:120-123). No token → `PUSH_URL` stays the
  clean https URL and the relay push fails "could not read Username".

## 2. Ack/relay semantics (the P1)

| Stage | Behavior | Provenance |
|---|---|---|
| pre-receive | validates plan/openspec YAML of pushed refs | pre-receive-hook.sh:103-148 |
| local accept | `receive.denyNonFastforwards=false`, `denyDeletes=false` — forge push ALWAYS lands locally | entrypoint.sh:67-68 |
| post-receive relay | synchronous per-ref push `NEWSHA:REFNAME` to upstream, token injected in-memory | post-receive-hook.sh:65-144 |
| relay failure | logged as WARNING, **hook still `exit 0`** — pusher sees success | post-receive-hook.sh:146-157 |
| startup retry | re-push each local head/tag by name; failures logged only | entrypoint.sh:142-188 |

**Finding A (verified, root cause of the macOS false-success P1):** the
success signal to the pusher is *local accept*, never *durable relay*. Relay
failure is indistinguishable from success at the forge (`exit 0` at
post-receive-hook.sh:157; the WARNING lines go to the push stderr stream but
agents/tools treat exit status as truth). With a missing/unreadable
vault-token secret the relay deterministically fails while every push "succeeds"
(plan/issues/git-mirror-push-false-success-not-relayed-2026-07-12.md — GitHub
stale 15 min behind an acked push; operator hypothesis "missing upstream
credentials in mirror" is consistent with post-receive-hook.sh:120-137).

**Finding B (verified, latent):** pre-receive's reject flag is set inside a
pipeline subshell (`echo "$FILES" | while … REJECTED=1; done`,
pre-receive-hook.sh:125-142), so `REJECTED` never propagates to the parent
and the final `exit 1` (:145-148) is unreachable. The YAML gate is currently
advisory noise, not a gate — independently confirmed by
plan/issues/mirror-pre-receive-openspec-yaml-reject-2026-07-12.md ("the
rejects are advisory, not blocking"). Separate defect there: ruby validator
rejects legal `Date` scalars in archived openspec files.

**Finding C (fixed in code, not yet live):** reconcile fetches used
`+refs/*:refs/*` and clobbered just-received exported refs (order 301, fixed
at entrypoint.sh:80-89 + seed at :148-158); live mirror still runs the old
image until order 302 rebuilds it.

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
(:66-104). **But** per Finding A, a *reachable* mirror that acks-and-drops
still satisfies the guard — reachability ≠ relay
(plan/issues/forge-credential-guard-push-channel-gap-2026-07-08.md;
git-mirror-push-false-success P1). GitHub token storage: Vault
`secret/github/token`, written by the GitHub Login flow, read only inside
the mirror at push time (post-receive-hook.sh:114-123).

## 6. Hack inventory → DEFAULTS OVER CONFIGURATION dispositions

| Mechanism | Why it exists | Breaks if removed | Git-native candidate | Disposition |
|---|---|---|---|---|
| insteadOf rewrites (3 variants: image-injected global, runtime global, repo-local) | route GitHub URLs to mirror without touching host config | forge pushes hit GitHub w/o creds | ONE canonical remote: clone from mirror with origin=mirror; present upstream as separate `upstream` remote, or keep exactly one injected-gitconfig insteadOf | replace-with-default (single injection point, all platforms) |
| post-receive `exit 0` always | never block forge UX | relay failures become blocking | proper mirror semantics: `receive.*` accept + **report relay state**; or make relay synchronous-failing (agent retries are cheap) | replace — ack must reflect relay (order 315 exit criterion) |
| token-in-URL `https://oauth2:TOKEN@` built in-shell | no credential helper in Alpine image | relay auth | `git credential` helper (`credential.helper` invoking vault-cli via the documented git-credential protocol); token never in argv/URL | replace-with-default |
| `http.sslCAInfo` enclave-CA-only + GIT_SSL_CAINFO combined-bundle band-aid | proxy MITM trust | git TLS through proxy | install combined CA at the DISTRO default path at image build (update-ca-certificates) → zero TLS env vars for every tool | replace-with-default |
| CA-block duplication in 6 entrypoints + lib-common | historical copy-paste | drift (already: COMBINED vs COMBINED_CA) | single lib-common function; better: image-baked trust store | delete-candidate (after trust-store fix) |
| transport selection by env-var presence | Windows lacks git daemon | wrong-transport confusion | one explicit `TILLANDSIAS_GIT_TRANSPORT={mirror-daemon,mirror-path,host-mount}` or derive from a single mirror URL | replace (1 var instead of 4) |
| `denyNonFastforwards=false` on mirror | initial host sync looks like force-push | first push rejected | seed mirror from upstream at init (entrypoint already fetches); then default `denyNonFastforwards=true` restores git's own safety | replace-with-default |
| credential guard forge branch trusting reachability | pre-push verifiability | none (it under-verifies today) | mirror exposes relay state (e.g. `refs/notes/relay` or status file over HTTP :8080); guard checks it | replace (pairs with ack fix) |
| tmpfs quarantines ~/.ssh, ~/.config/gh | host cred leak via source mount | cred leakage | keep — cheap, effective | keep-justified |
| pre-receive YAML gate | protect shared ledger | broken YAML reaches GitHub | fix subshell + `safe_load permitted_classes: [Date]`; keep as real gate | keep (after Finding B fix) |
| explicit per-ref refspecs everywhere (never `--mirror`) | `--mirror` nearly wiped upstream (wave 24) | catastrophic ref deletion | keep — this IS the enterprise practice for sparse mirrors | keep-justified |

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
4. Live mirror image still pre-order-301 (order 302 pending) — deploy state
   not verifiable from the tree.
