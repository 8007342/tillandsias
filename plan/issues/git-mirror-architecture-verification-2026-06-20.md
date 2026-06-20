# Git Mirror Architecture Verification — 2026-06-20

**Filed:** 2026-06-20T20:30Z
**Origin:** Operator request — verify git mirror is a real git server, not FS hooks
**Trace:** `spec:git-mirror-service`, `spec:tillandsias-vault`, `spec:secrets-management`

## Goal

Verify that `tillandsias-git` is a **real git server** (HTTPS or SSH with proper TLS
using the pre-seeded certificate authority) and not a filesystem-level hack (bind
mounts, file-copy hooks, symlinks to the host `.git/`).

## Current Understanding

From code review of `images/git/`:

- `images/git/entrypoint.sh` — initialises a bare git repo, sets up the post-receive hook
- `images/git/post-receive-hook.sh` — on every `git push` to the mirror, reads the GitHub
  token from Vault and relays the push to `github.com`
- `images/git/vault-cli.sh` — minimal Vault client shim (curl + jq; no binary)
- The container is named `tillandsias-git` and is accessed via the enclave network

**Unknown / to verify:**

1. What protocol does the git mirror serve? HTTP smart protocol? SSH? Both?
2. Does it use a real TLS cert (signed by the Tillandsias CA at `/tmp/tillandsias-ca/`)?
3. What URL does the forge shell use to reach the mirror (`git remote -v` inside forge)?
4. Does `git clone https://tillandsias-git/...` work from inside the forge?
5. Does the `tillandsias-router` route git traffic, or is the git container directly accessible?
6. Is there any filesystem shortcut (e.g. `url.<path>.insteadOf` pointing at a host path)?

## Verification Protocol

Run on mutable Linux host (big-pickle) with forge shell open:

```bash
# From host — check git container config
podman inspect tillandsias-git --format '{{json .NetworkSettings}}' 2>/dev/null | jq .
podman exec tillandsias-git cat /etc/gitconfig 2>/dev/null || true
podman exec tillandsias-git git config --list --system 2>/dev/null || true

# Verify TLS cert is from Tillandsias CA (not self-signed or FS hack)
openssl s_client -connect 127.0.0.1:<git-port> \
  -CAfile /tmp/tillandsias-ca/intermediate.crt </dev/null 2>&1 | grep -E 'Verify|subject|issuer'

# From inside forge — verify remote is a real HTTP endpoint
git remote -v
curl -v https://tillandsias-git/<repo>.git/info/refs?service=git-upload-pack \
  --cacert /opt/tillandsias/ca/intermediate.crt 2>&1 | head -30

# Verify post-receive actually runs (not a FS hook)
git log --oneline -1
echo "test" >> README.md && git commit -am "probe" && git push tillandsias-git <branch>
# Observe: does the push relay to GitHub?
```

## Red Flags That Would Indicate FS Hacks

- `git remote -v` inside forge shows a `file://` or `/host/path/...` URL
- No TLS (plain HTTP with no cert)
- `git push` succeeds but GitHub remote doesn't advance
- The "git server" is just a symlink to the host's `.git/objects/`
- `podman inspect` shows a bind mount of the host repo directory into the container

## Action Items

- `git-mirror-verify/protocol-probe`: confirm HTTP smart protocol or SSH with real TLS
- `git-mirror-verify/ca-cert-check`: verify cert is signed by Tillandsias intermediate CA
- `git-mirror-verify/forge-remote-check`: inside forge, confirm `origin` / mirror remote
  URL is a real network endpoint (not file://)
- `git-mirror-verify/post-receive-relay`: push from forge → git mirror → confirm GitHub
  remote advances
- `git-mirror-verify/findings`: file all findings to this document + reduce to fix packets
