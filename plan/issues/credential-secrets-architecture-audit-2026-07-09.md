# Credential & Secrets Architecture Audit

**Date:** 2026-07-09
**Classification:** audit+security+design
**Host:** any
**Observed by:** linux-big-pickle-20260709

## Observation

Credentials and secrets are managed across multiple backends (Vault, host keychain,
filesystem fallback, podman secrets, `.cache` directory) with inconsistent policies
for lifecycle, quarantine, and injection.

Specific findings:

1. **Git identity stored on host filesystem**: `~/.cache/tillandsias/secrets/git/.gitconfig`
   is written during `--github-login` but lives on the host, not in Vault. It should be
   stored in Vault KV and injected as a per-project podman secret when launching
   containers, ensuring consistent identity and transparent quarantine.

2. **No per-project credential injection**: Every container gets the same proxy env
   and vault token, but git identity, GitHub tokens, and API keys should be scoped
   per project mount so that a forge session for project A cannot push to project B's
   remotes.

3. **Credential quarantine is partial**: order 170 added tmpfs overlays for
   `/home/forge/.ssh`, `/home/forge/.config/gh`, `/home/forge/.config/git`, but the
   host's `~/.cache/tillandsias/secrets/git/.gitconfig` is not vault-mediated and
   could leak into the container through volume mounts or env vars.

4. **Vault token lifecycle**: vault tokens are created via AppRole with no explicit
   TTL or rotation policy for login sessions. Tokens may outlive their intended use.

## Impact

Credentials are spread across multiple stores with no unified policy. Git identity
is not yet vault-mediated, per-project credential isolation is incomplete, and token
lifecycles are implicit rather than declared. This creates a surface for accidental
credential cross-contamination between projects.

## Required Agents

At least 3 agents must verify this packet as complete:
- `opencode-bigpickle`
- `antigravity-gemini`
- `codex-gpt55-highthink`

## Deliverable

1. **Credential Store Inventory**: Every secret type (GitHub token, git identity,
   provider API keys, vault tokens, unseal keys, TLS certs) mapped to its current
   storage backend and lifecycle policy.

2. **Vault-Mediated Git Identity Design**: Move git name/email from
   `~/.cache/tillandsias/secrets/git/.gitconfig` to Vault KV at `secret/git/identity`,
   injected as a podman secret on per-project container launch. Host should never hold
   the raw identity after login.

3. **Per-Project Credential Scope**: Design for scoped podman secret injection so
   project A's forge cannot authenticate to project B's GitHub remote.

4. **Token Lifecycle & Rotation Policy**: TTLs, renewal windows, revocation on
   logout for every token type.

5. **Credential Quarantine Completion**: Audit order 170's tmpfs overlays and verify
   no host credential path bypasses them. Add litmus tests.

6. **Spec/Cheatsheet Patch List**: Files in `openspec/specs/` and `docs/cheatsheets/`
   that need updating.
