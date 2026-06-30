# Git Mirror Architecture Verification

**Packet:** `git-mirror-architecture-verification` (Order 69)
**Agent:** `linux-big-pickle-20260621T0432Z`
**Date:** 2026-06-21T04:32Z (UTC)
**Host:** linux_mutable (Fedora 44, Podman 5.8.2)

## Summary

Verified against the operator's original concern: the git mirror is NOT a
filesystem shortcut or `file:// insteadOf` hack on Linux. It is a real `git
daemon` server using the Git native protocol (`git://` on port 9418). The
post-receive hook pushes to GitHub via HTTPS using a Vault-fetched token.

Two edge findings: (1) the packet outcome wording says "HTTPS/SSH" but the
internal protocol is `git://` (native git daemon); (2) the Windows/WSL
filesystem transport does use a path-based `insteadOf` redirect that is
functionally akin to a `file://` redirect.

## Task Results

### git-mirror-verify/protocol-probe ✅

**Finding:** The git mirror serves the **Git native protocol** (`git://`) on port
9418 via `git daemon`, NOT HTTPS or SSH.

- `images/git/entrypoint.sh`:157–164 — `git daemon` started with
  `--base-path=/srv/git --enable=receive-pack --reuseaddr --export-all --port=9418`
- `crates/tillandsias-headless/src/main.rs`:1889 — same invocation confirmed in
  the container-image spec comment
- `crates/tillandsias-headless/src/main.rs`:2602 — `check_port git-service 9418 git`
  used in the runtime health check
- `images/default/lib-common.sh`:301 — forge remote rewritten to
  `git://git-service/${TILLANDSIAS_PROJECT}` for host-mount mode
- `images/default/lib-common.sh`:439 — network clone uses `git://` scheme

The `git://` native protocol is the correct choice for an enclave-internal
transport: no TLS overhead, no certificate management on the serving side,
and the port is blocked from outside the enclave network. Outbound relay to
GitHub uses HTTPS (authenticated via Vault token), not `git://`.

### git-mirror-verify/ca-cert-check ✅

**Finding:** The git daemon does NOT serve TLS. The CA cert
(`/etc/tillandsias/ca.crt`, bind-mounted from `certs_dir/intermediate.crt` at
line 1883–1885 of `main.rs`) is used for **outbound** connections from the
post-receive hook:

1. **Vault HTTPS API** — `CURL_CA_BUNDLE=/etc/tillandsias/ca.crt` with
   `VAULT_ADDR=https://vault:8200` (line 1870–1874 of `main.rs`) so `vault-cli`
   can connect to Vault's TLS endpoint within the enclave.
2. **GitHub HTTPS push** — `GIT_SSL_CAINFO=/etc/tillandsias/ca.crt` at line
   39–43 of `images/git/entrypoint.sh` so `git push` to `https://github.com/...`
   trusts the Tillandsias intermediate CA (which signs the proxy/egress
   certificate chain).

This is architecturally correct. The outcome field in the packet says
"served ... using certs from the pre-seeded Tillandsias CA", which is
misleading — the CA certs are not for serving TLS to clients but for the
mirror's outbound client-side TLS verification.

There is no TLS listener on the git mirror's port 9418, and none is needed:
`git://` is the correct protocol for an enclave-internal bridge.

### git-mirror-verify/forge-remote-check ✅

**Finding:** Inside a running forge on Linux, `git remote -v` shows a network
URL, NOT `file://`:

**Host-mount mode** (`TILLANDSIAS_PROJECT_HOST_MOUNT=1`):
- `git remote -v` shows the original GitHub URL (e.g.
  `https://github.com/owner/repo.git`)
- `git config --global url.git://git-service/<project>.insteadOf <GH-URL>`
  silently redirects transport to the mirror
- The host's `.git/config` is never touched — redirect lives in container's
  ephemeral `~/.gitconfig`

**Network clone mode** (no host mount; used by CLI/tray launches on Linux):
- `git remote -v` shows `git://git-service/<project>` directly
- `git remote set-url --push origin git://git-service/<project>` is set at
  clone time (lib-common.sh:442)

Neither mode shows `file://`. The `insteadOf` target is the network address
`git://git-service/<project>`, not a local filesystem path.

**Windows/WSL exception:** The WSL transport path (lib-common.sh:418) uses
`git config --local "url.${src}.insteadOf" "$github_url"` where `${src}` is the
bare-mirror path like `/mnt/c/.../bare-mirror.git`. Git interprets an absolute
path in `url.<path>.insteadOf` functionally like `file://<path>`. This IS a
`file://`-equivalent redirect, but only on Windows/WSL — NOT on Linux.

### git-mirror-verify/findings ✅

Compiled herein.

## Architecture Diagram (Linux/podman)

```
┌─────────────────────────────────────────────┐
│  Forge container                             │
│                                              │
│  git push origin main ─────────────────┐     │
│  (remote shows GH URL or               │     │
│   git://git-service/...)                │     │
│                                         │     │
│  git:// redirect via                    │     │
│  ~/.gitconfig insteadOf                 │     │
└───────────────────┬─────────────────────┘     │
                    │                           │
                    ▼                           │
┌──────────────────────────────────────┐        │
│  tillandsias-git container           │        │
│                                      │        │
│  git daemon --port=9418              │        │
│  /srv/git/<project>.git (bare repo)  │        │
│                                      │        │
│  post-receive hook fires ────────────┼────────┘
│                                      │
│  vault-cli → Vault → GitHub token    │
│                                      │
│  git push https://github.com/...     │
│  (explicit refspecs, not --mirror)   │
│                                      │
│  GIT_SSL_CAINFO=/etc/tillandsias/    │
│    ca.crt  (for outbound HTTPS)      │
└──────────────────┬───────────────────┘
                   │
                   ▼
         GitHub (upstream)
```

## Recommendations

1. **Correct packet outcome wording:** Update `plan/index.yaml` outcome field
   (line 4992–4994) from "real HTTPS/SSH git server using certs from the
   pre-seeded Tillandsias CA" to "real git daemon server (git://) with Vault-
   backed HTTPS relay; CA certs used for outbound connections, not serving".
   The current wording sets wrong expectations for future operators.

2. **No code changes needed on Linux.** The architecture is sound: `git daemon`
   for enclave-internal transport, Vault-authenticated HTTPS for upstream relay.

3. **Windows/WSL `file://`-equivalent redirect:** Document in
   `images/default/lib-common.sh` around line 418 that the path-based
   `url.<path>.insteadOf` is functionally a `file://` redirect. This is
   intentional for WSL (no `git daemon` on Windows host), but it should be
   clearly acknowledged rather than overlooked.

## Files Examined

- `images/git/entrypoint.sh` — git daemon startup, CA setup
- `images/git/Containerfile` — image definition (Alpine 3.20, git, vault-cli)
- `images/git/post-receive-hook.sh` — push relay (explicit refspecs, safety guard)
- `images/default/lib-common.sh` (lines 246–460) — `rewrite_origin_for_enclave_push`,
  `clone_project_from_mirror` with three transports
- `crates/tillandsias-headless/src/main.rs` (lines 1807–1892) — `build_git_run_args`,
  CA bind-mount, vault secret mount
- `crates/tillandsias-headless/src/main.rs` (lines 2602, 8048, 8170) — health
  check and diagnostic tests
- `plan/index.yaml` (lines 4983–5047) — packet definition
