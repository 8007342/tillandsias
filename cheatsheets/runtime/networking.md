# Enclave Networking

@trace spec:agent-source-of-truth

**Version baseline**: Tillandsias forge enclave (v0.1.170+, proxy v0.1+, git-service v0.1+, inference v0.1+)  
**Use when**: Understanding how the forge accesses external services, what's blocked, what's available locally

## Provenance

- https://github.com/8007342/tillandsias/blob/main/openspec/specs/enclave-network/spec.md — Enclave isolation design
- https://github.com/8007342/tillandsias/blob/main/openspec/specs/proxy-container/spec.md — Proxy container allowlist
- https://squid-cache.org/Doc/config/ — Squid proxy configuration
- **Last updated:** 2026-04-27

## Quick reference

| Service | Address | Protocol | Access | Purpose |
|---------|---------|----------|--------|---------|
| **Proxy** | `proxy:3128` | HTTP/HTTPS | ✅ Available | Outbound web access (domain allowlist applied) |
| **Git Mirror** | `git:9418` | git:// | ✅ Available | Clone from enclave-local bare mirror (authenticated push via D-Bus) |
| **Inference (ollama)** | `inference:11434` | HTTP | ✅ Available | Local LLM inference (no internet needed after model pull) |
| **External internet** | — | — | ❌ Blocked | Forge has zero external network access |
| **Host services** | — | — | ❌ Blocked | Forge cannot reach host SSH/X11/home dir; all I/O mediated by mirror/proxy |

## Common patterns

**Using the proxy for outbound HTTPS:**

```bash
# Proxy is auto-configured in the image; curl just works
curl https://api.github.com/repos/torvalds/linux  # Goes through proxy:3128

# pip, npm, etc. respect standard proxy env vars (pre-configured)
pip install numpy   # Uses proxy, subject to allowlist
npm install express # Uses proxy, subject to allowlist
```

**Cloning from the git mirror:**

```bash
# git daemon on git:9418 hosts mirrors of allowed repos
git clone git://git/my-org/my-repo.git ./my-repo
cd my-repo

# Push is authenticated via D-Bus → host keyring (push happens on host, not in forge)
# Forge sees changes as git daemon pull-only
git push origin main  # D-Bus → git-service → host keyring → GitHub
```

**Inference via ollama:**

```bash
# Tiny models are pre-pulled into the inference container
curl http://inference:11434/api/generate -d '{
  "model": "qwen2:0.5b",
  "prompt": "What is Rust?"
}'
```

**Checking what domains the proxy allows:**

```bash
# The proxy's allowlist is in the proxy container image
# From inside forge, you cannot inspect it directly, but you can test:
curl https://github.com  # Should work (GitHub is on allowlist)
curl https://example.com  # Depends on allowlist

# If a domain is blocked:
# → Write a RUNTIME_LIMITATIONS_NNN.md report
# → Include the domain you need + why (e.g., "PyPI mirror for offline pip install")
```

## Common pitfalls

❌ **Trying to access external services without proxy**: Forge has no external network. `curl https://api.example.com` fails. → Use the proxy via `curl -x http://proxy:3128 https://api.example.com`, or rely on pre-configured env vars (which apply to curl, wget, pip, npm, etc.).

❌ **Assuming `localhost` reaches the host**: The forge cannot reach host services on `127.0.0.1`. → Use the enclave-internal service names: `proxy`, `git`, `inference`.

❌ **Pushing commits via SSH from the forge**: SSH is not available inside the forge. → Git authentication happens via D-Bus to the host keyring. Just `git push origin main` and let the git-service handle it.

❌ **Pulling models at runtime**: ollama pull inside the forge will time out if the model is large and not pre-cached. → Either pre-pull on the host (host runs `ollama pull model-name` before attaching), or accept the first-run latency, or use a smaller model.

❌ **Assuming DNS works**: The forge may not have a working resolver for arbitrary domains. → Only rely on services inside the enclave (proxy, git, inference) or pre-configured external services (GitHub, PyPI, etc., through the proxy).

## See also

- `runtime/forge-container.md` — Mutable/immutable storage boundaries, how to debug container state
- `agents/claude-code.md` — Claude Code's proxy configuration
