---
tags: [forge, transparency, git, proxy, inference, network]
languages: []
since: 2026-06-23
last_verified: 2026-06-23
sources:
  - https://github.com/8007342/tillandsias
authority: high
status: current
tier: bundled
summary_generated_by: hand-curated
bundled_into_image: true
committed_for_project: false
---

# Forge Transparency Layer

**Use when**: Understanding which infrastructure services are transparently
handled — things you never need to configure, debug, or even think about.

## Design Principle

The forge is a **credential-free, zero-config workspace**. Everything behind
the scenes (git mirror, proxy cache, inference endpoint, Vault secrets) is
wired up before the agent sees the prompt. If it works for your project, it
works for **any** GitHub project the host user has cloned.

## Transparent Services

### Git Mirror (`git://tillandsias-git/<PROJECT>`)

Every `git push origin <branch>` and `git fetch` silently routes through the
enclave git daemon. The post-receive hook forwards pushes to GitHub using a
Vault-fetched token. No git config, no SSH keys, no personal access tokens:

```
$ git remote -v
origin  https://github.com/<user>/<repo>.git (fetch)
origin  https://github.com/<user>/<repo>.git (push)

$ git push origin main                     # transparently via git daemon
remote: [git-mirror] Push to origin: success

$ git fetch origin                         # transparently via git daemon
```

What to do:
- `git push`, `git fetch`, `git clone` work normally.
- If the project is new (no git history), the startup flow creates the repo.
- **Never** configure git remotes, tokens, or SSH inside the forge.

What NOT to do:
- Do NOT try to `git push` directly to `https://github.com/...` (no credentials).
- Do NOT troubleshoot git auth — the mirror handles it.
- Do NOT modify `~/.gitconfig` unless for transient aliases.

### HTTPS Proxy (Squid on `proxy:3128`)

Outbound HTTPS from the forge routes through the enclave proxy cache. The
CA chain is combined at startup so `curl`, `pip`, `cargo`, `npm`, etc. all
trust the proxy certificate transparently:
```
SSL_CERT_FILE=/tmp/tillandsias-combined-ca.crt
REQUESTS_CA_BUNDLE=/tmp/tillandsias-combined-ca.crt
NODE_EXTRA_CA_CERTS=<podman-env-injected>
```

What to do:
- `curl https://...`, `npm install`, `pip install` work normally.
- Package downloads are cached by the proxy — second+ installs are faster.

What NOT to do:
- Do NOT configure `HTTP_PROXY`/`HTTPS_PROXY` yourself (already set).
- Do NOT install custom CA certificates unless testing a new proxy.

### Inference Endpoint (`http://inference:11434`)

Ollama runs in a sidecar container. The forge connects over the enclave
network. The entrypoint probes readiness but does not block:

```
OPENAI_BASE_URL=http://inference:11434/v1
```

What to do:
- Use `http://inference:11434` for LLM inference from code.
- OpenCode/Claude already have this configured in their config overlay.

What NOT to do:
- Do NOT try to start Ollama inside the forge (it runs in its own container).

### Vault Secrets (`https://vault:8200`)

The git-mirror post-receive hook reads the GitHub token from Vault at push
time. Agent git identity (`GIT_AUTHOR_NAME`, `GIT_COMMITTER_NAME`) is seeded
from GitHub Login. The token is never stored on disk inside the forge.

What to do:
- `git commit` works with your identity automatically (trailer hook).
- `git push` authenticates via Vault — no manual token entry.

What NOT to do:
- Do NOT try to read Vault secrets directly (unnecessary).
- Do NOT store tokens in files, env vars, or git config.

## Per-Project Isolation

Every value that varies by project is resolved from the environment:

| Variable | Example (tillandsias) | Resolves to |
|---|---|---|
| `$TILLANDSIAS_PROJECT` | `tillandsias` | The repo name |
| `$PROJECT` | `tillandsias` | Same, short form |
| `git://tillandsias-git/<PROJECT>` | `git://tillandsias-git/tillandsias` | Mirror path |
| `/srv/git/<PROJECT>` | `/srv/git/tillandsias` | Bare repo in git container |
| `tillandsias-mirror-<PROJECT>` | `tillandsias-mirror-tillandsias` | Podman volume name |
| `tillandsias-git-<PROJECT>` | `tillandsias-git-tillandsias` | Git container name |
| `/home/forge/src/<PROJECT>` | `/home/forge/src/tillandsias` | Workspace path |
| `$HOME/.cache/tillandsias-project/` | per-project subdir | Project cache |

All infrastructure hostnames (`tillandsias-git`, `git-service`, `proxy`,
`vault`, `inference`) are product names that stay constant regardless of
which project is loaded. The `PROJECT` variable is the only moving part.
