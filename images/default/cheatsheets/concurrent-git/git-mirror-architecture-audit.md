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

All file:line references were refreshed through the order-320 Linux checkpoint
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

## 3. Config and trust injection into forges - per platform

As of orders 320/321, configuration and trust are owned by the shared Linux
guest implementation. Both forge launch builders generate one whitelist and
mount it read-only at Git's standard `/home/forge/.gitconfig` path. They mount
the public runtime CA once at `/run/tillandsias/ca-chain.crt`; the default image
atomically composes it with Fedora vendor roots at its system-default trust
path. No forge launcher or default-image entrypoint sets a Git-, OpenSSL-,
Requests-, or Node-specific CA override.

| Lane | Shared implementation path | Host-specific Git/CA override | Verification state |
|---|---|---|---|
| Linux podman | native tray/CLI calls the shared headless forge builders and default image | none | live config-origin, mirror-redirect, Git/curl/Node/Python TLS fixtures pass |
| macOS VZ | guest systemd and tray `--opencode` exec `/usr/local/bin/tillandsias-headless` | none found in VZ or tray sources | source parity passes; current-build live gate remains |
| Windows WSL | guest systemd execs `/usr/local/bin/tillandsias-headless` | none found in WSL or tray sources | source parity passes; current-build live gate remains |

The live qualification matters: VZ may fetch a release binary when no staged
guest exists, and an already registered WSL distro can retain its installed
binary. Therefore source parity does not substitute for live evidence from a
locally built/current tray on each sibling host.

**Finding D (host↔forge bidirectional leak, verified by evidence chain):**
the Linux host-mount lane bind-mounts the host checkout RW
(main.rs:7621-7625), so the forge's repo-local `git config` writes land in
the HOST's `.git/config`. All Tillandsias-owned code carefully writes
`--global` only (lib-common.sh:355-380 comments), but any AGENT inside the
forge can (and on macOS did) write `.git/config` directly — poisoning the
host (osx-next 258327d6 "insteadOf host-poisoning addendum"). Conversely the
host's `.git/config` (origin URL, hooks, helpers) flows INTO the forge. The
quarantine covers `~/.ssh`/`~/.config/gh` but NOT the project `.git/`.

**Resolution (2026-07-14, order 321):** both Linux forge launch builders now
mount a writable Tillandsias-owned `.git` facade after the host worktree and
then mount only the host object database and loose refs beneath it. The facade
config is rebuilt from a whitelist, strips HTTPS userinfo, disables automatic
ref packing, and never copies host credential helpers, includes, URL rewrites,
hooks, or index writes back to the checkout. The rootless Podman fixture
`scripts/test-forge-gitconfig-bidirectional-quarantine.sh` proves host config is
byte-identical after forge-local `git config` edits while fetch, commit, shared
objects/refs, and upstream push still converge.

## 4. Forge Git-flow environment inventory

Scope is deliberately mechanical: production environment values injected into
a forge whose purpose is configuring Git behavior. Standard proxy protocol
variables, product/project metadata, host-only credentials, mirror-container
internals, and command-local test/index isolation are reported separately and
do not count as forge Git configuration.

| Logical value | Environment names | Justification |
|---|---|---|
| commit identity name | `GIT_AUTHOR_NAME`, `GIT_COMMITTER_NAME` | one non-secret name is copied into Git's standard author/committer interfaces without mutating shared config |
| commit identity email | `GIT_AUTHOR_EMAIL`, `GIT_COMMITTER_EMAIL` | one non-secret email is copied into Git's standard author/committer interfaces without mutating shared config |

Count: **2 justified Git-flow values**. There are no production forge
`GIT_CONFIG_GLOBAL`, `GIT_SSL_CAINFO`, `SSL_CERT_FILE`,
`REQUESTS_CA_BUNDLE`, `NODE_EXTRA_CA_CERTS`, or `CURL_CA_BUNDLE` values.

Surrounding runtime contracts remain but are not Git configuration:
standard upper/lowercase proxy variables define enclave egress;
`TILLANDSIAS_PROJECT`, `TILLANDSIAS_PROJECT_HOST_MOUNT`,
`TILLANDSIAS_GIT_SERVICE`, and `TILLANDSIAS_GIT_MIRROR_PATH` describe project
and transport topology; host `GH_TOKEN`/`GITHUB_TOKEN` never enter a forge;
and `VAULT_ADDR` plus any Git-service CA setting are mirror-container only.

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
| insteadOf rewrites | route GitHub URLs to mirror without touching host config | forge pushes hit GitHub w/o creds | one generated read-only standard global config, plus the transport-specific remote set by shared guest code | converged (orders 320/321; live sibling verification pending) |
| pre-receive atomic relay | make client success mean configured-upstream durability | false-success data loss returns if removed | keep synchronous `git push --atomic` with explicit refspecs; post-receive remains bookkeeping only | keep-justified (order 318 fixture) |
| token-in-URL `https://oauth2:TOKEN@` built in-shell | no credential helper in Alpine image | relay auth | `git credential` helper (`credential.helper` invoking vault-cli via the documented git-credential protocol); token never in argv/URL | replace-with-default |
| `http.sslCAInfo` enclave-CA-only + per-client CA overrides | proxy MITM trust | git TLS through proxy | immutable vendor roots plus one runtime CA input at the distro-default path | removed (order 320 runtime trust fixture) |
| CA-block duplication in 6 entrypoints + lib-common | historical copy-paste | drift (already: COMBINED vs COMBINED_CA) | one fail-loud rootless initializer | removed (order 320) |
| transport selection by env-var presence | Windows lacks git daemon | wrong-transport confusion | one explicit `TILLANDSIAS_GIT_TRANSPORT={mirror-daemon,mirror-path,host-mount}` or derive from a single mirror URL | replace (1 var instead of 4) |
| `denyNonFastforwards=false` on mirror | initial host sync looks like force-push | first push rejected | seed mirror from upstream at init (entrypoint already fetches); then default `denyNonFastforwards=true` restores git's own safety | replace-with-default |
| credential guard forge branch trusting reachability | pre-push verifiability | none (it under-verifies today) | mirror exposes relay state (e.g. `refs/notes/relay` or status file over HTTP :8080); guard checks it | replace (pairs with ack fix) |
| tmpfs quarantines ~/.ssh, ~/.config/gh | host cred leak via source mount | cred leakage | keep — cheap, effective | keep-justified |
| pre-receive YAML gate | protect shared ledger | broken YAML reaches GitHub | fix subshell + `safe_load permitted_classes: [Date]`; keep as real gate | keep (after Finding B fix) |
| explicit per-ref refspecs everywhere (never `--mirror`) | `--mirror` nearly wiped upstream (wave 24) | catastrophic ref deletion | keep — this IS the enterprise practice for sparse mirrors | keep-justified |

### Explicit environment-variable dispositions

These rows retain the original audit scope and record the current disposition.

| Variable | Disposition | Default or retained contract |
|---|---|---|
| `GIT_CONFIG_GLOBAL` | removed from forge production | Git reads the generated read-only `/home/forge/.gitconfig` through its standard lookup. Command-local `/dev/null` isolation remains outside production launch. |
| `GIT_SSL_CAINFO` | removed from forge production | Git/libcurl use the default image trust bundle. A mirror-container-only setting remains outside the forge. |
| `SSL_CERT_FILE` | removed from forge production | Forge clients use the default image trust bundle. A Chromium-container setting remains outside the forge. |
| `REQUESTS_CA_BUNDLE` | removed | Python/Requests uses the default image trust bundle. |
| `NODE_EXTRA_CA_CERTS` | removed | The image enables Node system-CA behavior. |
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
| `TILLANDSIAS_GIT_SERVICE` | keep as topology metadata | Selects the guest-visible network mirror; not a Git configuration override. |
| `TILLANDSIAS_GIT_MIRROR_PATH` | keep as topology metadata | Selects the WSL filesystem mirror; not a Git configuration override. |
| `TILLANDSIAS_PROJECT_REMOTE_URL` | replace-with-default | Persist the clean upstream as the bare repository's `origin` during mirror creation instead of exposing it to every process. |
| `GIT_AUTHOR_NAME` | keep-justified | Standard Git non-secret identity interface; avoids mutating shared configuration. |
| `GIT_AUTHOR_EMAIL` | keep-justified | Standard Git non-secret identity interface; avoids mutating shared configuration. |
| `GIT_COMMITTER_NAME` | keep-justified | Standard Git non-secret identity interface; avoids mutating shared configuration. |
| `GIT_COMMITTER_EMAIL` | keep-justified | Standard Git non-secret identity interface; avoids mutating shared configuration. |
| `VAULT_ADDR` | keep-justified | Standard Vault client endpoint, scoped to the mirror container. |
| `VAULT_ROLE` | delete | The current baked `vault-cli` consumes the mounted token and `VAULT_ADDR`; it never reads this launcher-only label. |
| `CURL_CA_BUNDLE` | removed from forge production | curl uses the default image trust bundle; mirror-container use is separately scoped. |

## Open questions (not fully verifiable from the tree)

1. Whether a locally built/current macOS guest reports the standard config
   origin and mirror redirect without a host edit. Source parity passes, but a
   release-download fallback can otherwise execute an older guest binary.
2. Whether the macOS guest mirror container receives the vault-token secret
   at all (the false-success P1's credential hypothesis) — requires in-guest
   `podman inspect tillandsias-git-<p>`.
3. Whether a locally built/current Windows WSL guest reports the same config
   origin and TLS behavior. Registered distros may retain an installed binary,
   so the live gate must prove the guest revision before collecting evidence.
4. Whether Windows/WSL bare-mirror hooks execute with vault-cli available
   (post-receive-hook.sh:15-19 says hooks run in the forge distro context —
   token path there is unclear).
