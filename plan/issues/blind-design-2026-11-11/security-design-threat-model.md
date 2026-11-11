# Threat model — a tray-launched regional cloud of agent forges

Blind design, derived from the product promise only. Method: assets → actors →
trust boundaries → STRIDE per boundary [R1], with the LLM-agent specifics taken
from the OWASP LLM Top 10 [R2] and the "lethal trifecta" framing [R3], and the
container specifics from NIST SP 800-190 [R4].

Citations were written from the author's knowledge of these public documents;
none was re-fetched in this session (see `learnings.md`, L14). Open facts are in
`questions.md` (Qn).

## 1. System as assumed

```
 operator ── OS session ── TRAY (unprivileged, user-owned)
                              │  owns
                              ▼
                 BROKER (host process; the only holder of unsealed secrets)
                  │ vault file (AEAD) ── key wrapped by OS keystore / TPM / SE
                  │ approval UI (OS user verification)
                  ▼
   ┌──────────── container substrate ─────────────────────────────┐
   │ Linux: rootless podman, direct                               │
   │ macOS: podman machine VM (applehv/libkrun)                   │
   │ Windows: podman machine in a WSL2 distro                     │
   │                                                              │
   │  per-project internal network (no route out)                 │
   │   ├─ forge (agent runs here; UNTRUSTED)                      │
   │   ├─ egress gateway   (injects provider credentials)         │
   │   ├─ git relay        (local mirror; pushes upstream)        │
   │   ├─ deploy relay     (Cloudflare)                           │
   │   └─ inference        (local models, read-only weights)      │
   └──────────────────────────────────────────────────────────────┘
```

The relays are "credential-using services": they hold a short-lived upstream
token in memory, obtained from the broker, on behalf of exactly one project.

## 2. Assets

| # | Asset | Why it matters |
|---|-------|----------------|
| A1 | Long-lived upstream grants: GitHub refresh/App key, provider OAuth refresh tokens or API keys, Cloudflare parent token | Account takeover, spend, supply-chain reach into every repo the operator can push to |
| A2 | Short-lived upstream tokens (installation tokens, access tokens, child tokens) | Same reach, bounded by scope and TTL |
| A3 | Vault key and its wrapping key | Unlocks all of A1 |
| A4 | Approval capability (the ability to produce a "the operator verified this action" assertion) | Converts an agent request into money spent or data destroyed |
| A5 | Project source and unpushed work | Confidentiality, integrity |
| A6 | Other projects' source, and the operator's home directory | Lateral blast radius |
| A7 | The operator's upstream identity (commits, PRs, deploys made in their name) | Reputation; downstream supply chain |
| A8 | Images, model weights, docs/cheatsheets fed to agents | Whoever controls these controls the agent |
| A9 | Licence-acceptance records | Legal exposure if forged, lost, or misattributed |
| A10 | Audit log | Without it nothing above is detectable |
| A11 | Provider quota / cloud budget | Direct cost |

## 3. Actors

| Actor | Position | Capability assumed | Goal |
|-------|----------|--------------------|------|
| T1 Malicious or hijacked agent | Inside a forge, arbitrary code execution as the forge user, reads everything the forge can read, speaks to every socket the forge can reach | Prompt-injected via repo content, web pages, docs, tool output [R2 LLM01] | Exfiltrate A1/A2/A5, spend A11, push malicious code as A7, escape to A6 |
| T2 Compromised dependency | Runs in a forge at install/build time (npm postinstall, build.rs, pip sdist), or baked into an image, or inside a model file | Same as T1 but silent and persistent across forges using the same image/cache | Credential theft, backdoor in pushed code |
| T3 Other local user | Different UID on the same machine (shared workstation, lab box) | Reads world-readable files, connects to loopback TCP ports and abstract sockets, sees `ps` argv | Use the operator's broker/relays; read tokens |
| T4 Thief with the laptop | Offline disk access; possibly a logged-in but locked session; possibly an unlocked session for minutes | Disk imaging, cold boot is out of scope | A1 from disk; push/deploy from an unlocked session |
| T5 Network attacker | LAN or on-path | Reaches any port bound to non-loopback; TLS interception without a trusted CA is out of scope | Reach relays, poison downloads |
| T6 Malicious project | A repo the operator opens in good faith | Controls repo config the tooling honours (git hooks, devcontainer-like files, agent instruction files, MCP config) | Become T1 at open time; request broader scopes |
| T7 Compromised upstream | Registry, model hub, docs source, or the product's own release channel | Serves altered artefacts | Become T2 everywhere |
| T8 The operator in a hurry | Legitimate | Approves prompts without reading | Not malicious; the design must not depend on diligence |

Explicitly out of scope: kernel 0-days, hypervisor escapes, a root-level host
compromise, hardware attacks on TPM/Secure Enclave, a coerced operator. A host
root attacker defeats every software vault; the design only promises that such
an attacker finds nothing *at rest* that is not encrypted (T4).

## 4. Trust boundaries

B1 **operator ↔ tray/broker** — OS session. The broker trusts the session
user for ordinary actions and requires fresh OS user verification for A4.

B2 **broker ↔ container substrate** — the broker hands out capabilities, never
A1. Crossing this boundary downward: short-lived A2 only, only to relays.

B3 **relay ↔ forge** — the hard boundary. The forge is hostile. Only
project-scoped *requests* cross upward; no credential crosses downward.

B4 **forge ↔ forge / project ↔ project** — separate networks, separate
volumes, separate relay instances or strictly keyed tenancy.

B5 **substrate ↔ internet** — only gateways and relays have a route out.

B6 **operator's user ↔ other local users** — file modes, socket modes, no TCP
listeners without authentication.

B7 **artefact source ↔ install** — signature and digest verification.

### Per-platform shape of B2/B6

| | Linux | macOS | Windows |
|-|-------|-------|---------|
| Substrate | Rootless podman, user namespaces, seccomp, SELinux where present [R5] | Podman machine: a Linux VM under Apple's hypervisor [R6] | Podman machine as a WSL2 distro [R6] |
| Isolation strength of B2 | Kernel namespaces only — a shared kernel with the host. Weakest of the three | VM boundary plus namespaces | VM boundary (shared utility VM across *all* WSL distros) plus namespaces |
| Default holes to close | `podman.sock` exposure; `$XDG_RUNTIME_DIR` contents; D-Bus session socket; abstract unix sockets share the host netns if `--network=host` is ever used | Default machine config mounts host home directories into the VM [Q4]; anything in the VM can then read `~/.ssh`, browser profiles, etc. | WSL automounts all Windows drives at `/mnt/*` and enables interop, so a Linux process can execute Windows binaries as the user [R7]; other WSL distros share the kernel and a network namespace |
| Keystore for A3 | Secret Service (locked with the login keyring) [R8]; TPM2 via `systemd-creds` where available [R9]. No hardware-bound, user-presence-gated key in the general case | Keychain item with access control bound to biometry or device passcode; Secure Enclave keys [R10] | DPAPI / Credential Manager; Windows Hello key in TPM [R11] |
| User verification for A4 | polkit agent + fprintd, or FIDO2 authenticator. No OS-guaranteed trusted path on most desktops [Q7] | LocalAuthentication (Touch ID / passcode) [R10] | `UserConsentVerifier` / Windows Hello [R11] |
| Other-local-user exposure (B6) | Loopback ports are shared by all UIDs; unix sockets in `$XDG_RUNTIME_DIR` (0700) are not | Same for loopback; per-user `$TMPDIR` | Same for loopback; named pipes need explicit ACLs |

Consequences that the credential design must absorb:

- On Linux the broker cannot live "behind a VM"; so it must hold secrets in a
  separate process the forge UID mapping cannot ptrace or read, and the forge
  must run with a distinct subordinate UID range, `no-new-privileges`, dropped
  capabilities and no host PID/IPC/network namespace.
- On Windows the tillandsias distro must be configured with interop and
  automount **off** [R7], otherwise B2 does not exist: a forge escape to the
  distro is an escape to the Windows user.
- On macOS the VM must mount only project directories, never `$HOME`.
- Loopback TCP is not a boundary against T3 on any platform. Every host-side
  listener is a unix socket / ACL'd named pipe, or authenticates each request.

## 5. STRIDE by boundary

Mitigations name the invariant (I-n) from `credential-design.md` §2.

### B3 forge ↔ relay (actors T1, T2, T6)

| | Threat | Mitigation |
|-|--------|-----------|
| S | Forge A claims to be forge B, or project X claims project Y, to use Y's grants | Identity is the socket/network the request arrived on, assigned by the broker at forge creation; nothing the forge sends is believed (I4) |
| S | Agent forges commit authorship or pushes as the operator to a branch the operator did not intend | Git relay enforces a per-project ref policy; commits made in forges carry a forge-attributed trailer/committer; protected refs need approval (I7) |
| T | Agent rewrites upstream history, deletes branches, alters CI config to exfiltrate CI secrets | Ref policy: no force-push or delete outside the agent's own namespace; changes to workflow/CI paths flagged as approval-class |
| T | Agent tampers with relay config, allowlists, or its own scope | Config is mounted read-only from outside or not mounted at all; scope changes only via broker + approval |
| R | Agent denies having deployed/pushed | Relay-side audit event per upstream call, hash-chained, outside the forge (I9) |
| I | Agent reads a credential from env, file, proc, logs, transcripts, layer, history | No credential is ever inside the forge (I2). This is the central design choice: a hijacked agent cannot leak what it never had |
| I | Agent exfiltrates source/secrets through an allowed channel (model provider prompt, git push to an attacker fork, DNS, deploy of a page containing data) | Egress allowlist per forge (I3); git remote is fixed by the relay; DNS answered only by the gateway; deploy targets fixed per project. Residual: the model provider itself is an exfil channel and cannot be closed [R3] — accepted, stated |
| I | Cross-tenant leak through a shared inference server (prompt cache, KV cache, logs) | Per-project context isolation or per-project instances; no request logging of bodies [Q12] |
| D | Agent burns provider quota or CF usage, floods the relay | Per-forge rate and budget caps in the gateway; cost-class actions need approval (I7) |
| E | Agent uses the relay as a confused deputy: asks it to do something broader than the forge may do | Relays expose verbs, not tokens; every verb is checked against the forge's scope; no generic "proxy this URL with auth" endpoint |
| E | Container escape | Rootless, no privileged, no engine socket, seccomp, cap-drop, read-only root where possible (I12); VM on macOS/Windows |
| E | Agent manufactures an approval (spoofs or auto-clicks the prompt, or phrases a request so the prompt reads innocently) | Prompt is rendered by the host from structured fields, never agent prose; verification is by OS API bound to the request digest (I7) |

### B2 broker ↔ substrate

| | Threat | Mitigation |
|-|--------|-----------|
| S | A non-relay container asks the broker for an upstream token | Broker socket is mounted only into relays; relays are started by the broker from verified image digests (I10) |
| T/I | A compromised relay image leaks A2 | Relay holds only one project's short-lived, minimally scoped token (I6); relay images are the smallest, most strictly verified artefacts |
| I | Secret lands in `podman inspect`, image layer, `podman secret` plaintext file store [R12], container log, journald | Secrets cross only as a file descriptor / in-memory response on a unix socket; never as `-e`, `--env-file`, build arg, label, or default-driver podman secret (I1, I2) |
| D | Broker down → everything stalls | Fail closed. Relays keep working until their current token expires, then stop |

### B1 / B6 host (actors T3, T4, T8)

| | Threat | Mitigation |
|-|--------|-----------|
| S | T3 connects to a loopback port and uses the relay or broker | No unauthenticated TCP listeners (I13) |
| I | T4 images the disk | Vault is AEAD-encrypted; key wrapped by OS keystore/TPM/SE; no other copy of any credential anywhere (I1). Full-disk encryption is recommended but not relied on |
| I | T4 has an unlocked session | Vault key release needs session unlock; cost/destructive actions additionally need fresh user verification (I7). Residual: an unlocked session can still drive ordinary pushes within existing project scope |
| I | Secrets in swap, core dumps, crash reports | Broker: `mlock`, no core dumps, zeroize; relays likewise. Residual on hibernation without FDE [Q9] |
| T | T3/T4 swaps the vault for an older copy (rollback to a revoked token) | Vault carries a monotonic counter bound into the keystore item; mismatch → treat as unopenable → wipe (I8) |
| R | Operator disputes an approval | Approval record stores request digest, verifier type, time; signed by a keystore-held key |
| E | T8 approves blindly | Approvals are rare by design (only cost/destructive), specific, and show a diff of consequence. Approval fatigue is a design defect to be measured, not a user failing |

### B5 / B7 network and artefacts (actors T5, T7) — detail in `supply-chain.md`

| | Threat | Mitigation |
|-|--------|-----------|
| S/T | Altered image, model, cheatsheet, or tray update | Digest pinning + signature + provenance verification before use, fail closed (I10) |
| T | Model file executes code on load (pickle) or carries a poisoned chat template | Data-only formats; template treated as untrusted input [S-ref in supply-chain.md] |
| I | Poisoned doc instructs agents to exfiltrate | Docs are agent input ⇒ they are code. Same provenance bar as images; and I2/I3 bound the damage when it happens anyway |
| D | Registry outage / rate limit | Local content-addressed cache; verified once, re-verified by digest |

## 6. The agent-specific argument

An agent has the lethal trifecta whenever it holds (a) private data, (b)
exposure to untrusted content, (c) a way to communicate out [R3]. A coding
forge cannot remove (a) or (b). The design therefore:

1. removes *credentials* from (a) entirely — the most valuable private data is
   simply absent (I2);
2. narrows (c) to named destinations with named verbs (I3);
3. puts a human, verified by the OS, in front of the irreversible and the
   expensive (I7);
4. accepts and documents the residue: project source can leak to the model
   provider and to the project's own remote, and an agent can push bad code
   within its ref namespace.

Prompt-injection *detection* is not a control in this model. Nothing here
relies on the agent, or a classifier, noticing an attack [R2].

## 7. Residual risks accepted

1. Source exfiltration via the model provider channel.
2. Malicious-but-in-scope pushes to agent-namespace branches.
3. Linux has a weaker B2 (shared kernel) and a weaker A4 (no universal
   trusted path) than the other two platforms.
4. A host-root or same-UID malicious process outside the product can ptrace
   the broker on platforms that allow it [Q8].
5. Providers whose only credential is a long-lived, unscoped key cap I6 at
   "long-lived, but never in a forge".

## References

- [R1] Microsoft, STRIDE threat categories — https://learn.microsoft.com/en-us/azure/security/develop/threat-modeling-tool-threats
- [R2] OWASP Top 10 for LLM Applications (2025) — https://genai.owasp.org/llm-top-10/
- [R3] S. Willison, "The lethal trifecta for AI agents" — https://simonwillison.net/2025/Jun/16/the-lethal-trifecta/
- [R4] NIST SP 800-190, Application Container Security Guide — https://csrc.nist.gov/pubs/sp/800/190/final
- [R5] Podman rootless tutorial — https://github.com/containers/podman/blob/main/docs/tutorials/rootless_tutorial.md
- [R6] `podman machine init` — https://docs.podman.io/en/latest/markdown/podman-machine-init.1.html
- [R7] Microsoft, Advanced settings configuration in WSL (`wsl.conf` `[interop]`, `[automount]`) — https://learn.microsoft.com/en-us/windows/wsl/wsl-config
- [R8] freedesktop.org Secret Service API — https://specifications.freedesktop.org/secret-service/latest/
- [R9] `systemd-creds` — https://www.freedesktop.org/software/systemd/man/latest/systemd-creds.html
- [R10] Apple, LocalAuthentication and `SecAccessControlCreateFlags` — https://developer.apple.com/documentation/localauthentication , https://developer.apple.com/documentation/security/secaccesscontrolcreateflags
- [R11] Microsoft, `UserConsentVerifier` and `CryptProtectData` — https://learn.microsoft.com/en-us/uwp/api/windows.security.credentials.ui.userconsentverifier , https://learn.microsoft.com/en-us/windows/win32/api/dpapi/nf-dpapi-cryptprotectdata
- [R12] `podman secret create` (driver `file` is the default) — https://docs.podman.io/en/latest/markdown/podman-secret-create.1.html
