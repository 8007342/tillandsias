# Security and Privacy Audit - Tillandsias (2026-05-27)

## Executive Summary
A holistic security and privacy audit of the Tillandsias spec (`methodology.yaml`, `plan.yaml`, and `openspec/specs/`) was conducted. While the architecture robustly models a zero-trust, ephemeral, and portable cloud region (e.g., enclave networks, vault-backed secrets, isolated browser containers), several critical security holes were identified that compromise the zero-tolerance policy. 

Below are the findings and proposed actionable enhancements for the orchestrator to approve and the host implementations (Linux, Windows, macOS) to adopt.

---

## 1. SELinux Isolation Gap (Zero-Tolerance Hardening)
**Hole:**
The `security-privacy-isolation` spec mandates `--security-opt=label=disable` as an immutable safety envelope for container launches. While `label=disable` is a pragmatic fallback for WSL2 and macOS (which lack SELinux support), applying this globally to native Linux hosts completely strips the kernel-level Mandatory Access Control (MAC) boundary.

**Proposed Enhancement:**
- **Platform-Aware Launch Profiles:** Modify the immutable defaults to be host-aware. 
- **Linux Native:** Enforce SELinux confinement by default (e.g., `--security-opt=label=type:tillandsias_forge_t`). Provide `.te` SELinux modules for Tillandsias containers to constrain file and socket access at the kernel level.
- **WSL2 / macOS:** Continue using `label=disable` explicitly as a known degraded state where LSM is absent.

## 2. Forge Container Privilege & AI Agent User Mapping
**Hole:**
The `forge-offline` spec explicitly forbids credentials and direct internet access, but it does not mandate user privilege boundaries *inside* the container. Even with `--cap-drop=ALL` and `--userns=keep-id`, if AI agents (Opencode/Codex/Claude) run as `root` (UID 0) inside the container, they bypass internal file permissions and increase the risk of container escape vectors.

**Proposed Enhancement:**
- **Strict UID/GID Boundaries:** Mandate that all agent processes execute as an unprivileged user (e.g., `forge` UID 1000) inside the container.
- **Immutable Rootfs:** Configure the forge container with `--read-only` rootfs (where possible) and remove all `setuid`/`setgid` binaries from the forge image to eliminate privilege escalation paths.

## 3. Proxy MITM Vulnerability & SSRF Risks
**Hole:**
The `proxy-container` spec explicitly states that `DONT_VERIFY_PEER` is set in `tls_outgoing_options`. This entirely defeats TLS security, leaving the proxy (and thereby all package installations like `npm`, `cargo`, `pip`) vulnerable to MITM attacks. Furthermore, forwarding `*.localhost` to an internal router without strict IP validation opens potential Server-Side Request Forgery (SSRF) and DNS rebinding attacks from compromised forge containers.

**Proposed Enhancement:**
- **Enforce Upstream TLS:** Immediately remove `DONT_VERIFY_PEER`. Enforce strict upstream CA validation (`/etc/ssl/certs/ca-certificates.crt`).
- **Strict Local Routing:** Implement DNS pinning for `*.localhost` to strict enclave IPs and drop all external DNS resolution for internal domain suffixes to close SSRF vectors.

## 4. Secret Leakage Risk (AI Agent API Keys)
**Hole:**
The `forge-offline` spec mandates zero credentials in the forge, and the `tillandsias-vault` spec states forge containers receive no Vault tokens. However, for Claude/Codex to function (if not using local inference), they require external API keys (e.g., `ANTHROPIC_API_KEY`). If these keys are injected as environment variables or bind-mounted, the zero-credential boundary is violated.

**Proposed Enhancement:**
- **API Gateway Pattern / Header Injection:** Ensure API keys never enter the forge container. Instead, use the proxy's `ssl-bump` capability (or a dedicated API gateway container) to dynamically inject the `Authorization` header for requests matching `.anthropic.com` or `.openai.com`. The AI agent only knows to route requests through the proxy, remaining entirely oblivious to the actual API key.

## 5. Vault Auto-Unseal & Machine Identity Weakness
**Hole:**
The `tillandsias-vault` spec derives the auto-unseal key from an `installation-uuid` stored as a static file (`~/.config/tillandsias/installation-uuid` mode `0600`). A host-level compromise easily exfiltrates this UUID, breaking the vault's security model.

**Proposed Enhancement:**
- **Hardware-Backed Identity:** Bind the `installation-uuid` to TPM 2.0 (Linux/Windows) or the Secure Enclave (macOS) hardware measurements. The unseal key should only be derivable if the hardware attestation succeeds, preventing offline attacks if the host disk is copied.
