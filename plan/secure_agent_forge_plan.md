# Secure Agent Forge: Integration & Development Plan

This plan details the architectural shift from NanoClaw to ZeroClaw, integrating it alongside OneCLI into a secure, Rust-based, Fedora/Podman local enclave environment. Work is divided into well-defined "Packets" for automatic pickup by Linux host workers.

## Architectural Decision: ZeroClaw vs NanoClaw
*   **Language & Simplicity:** We strictly prefer Rust. NanoClaw's orchestrator is built in Node.js/TypeScript. By shifting to **ZeroClaw**—a pure, minimalist Rust implementation of the same architecture—we keep the hot path simple, secure, and entirely in Rust.
*   **Licensing Strategy:** NanoClaw operates under the MIT license, which we avoid. ZeroClaw is dual-licensed (MIT and Apache 2.0), allowing us to consume it strictly under the **Apache 2.0** license. OneCLI is also licensed under Apache 2.0. This eliminates any MIT license concerns from our core dependencies.

## Meta-Orchestration Directive
**Skill: `/meta-orchestration` (Reduction Engine)**
When executing any packet or addressing an open issue, if the problem is too ambiguous or uncertain, the worker MUST invoke the `/meta-orchestration` skill. This acts as a reduction engine to split the ambiguous problem into a dedicated research phase and append smaller, well-defined development work packets directly to this plan before proceeding.

---

## Architecture: Layered Fedora 44 Container Strategy
To ensure incredibly fast installation and development updates, the container images will be structured in three layers:
1. **Layer 1 (Base):** A clean `fedora:44` base image populated with essential tools.
2. **Layer 2 (Engine):** The `zeroclaw` Rust engine image, built on top of Layer 1.
3. **Layer 3 (Forge):** The custom Forge environment, built on top of the Layer 2 ZeroClaw image.

---

## Work Packets

### Packet 1: Core Container Layering & Podman Migration
**Objective:** Establish the Fedora 44 container pipeline and migrate to the ZeroClaw Rust engine.
*   **Task 1.1:** Create `Containerfile.base` using `fedora:44` and install base OS dependencies and networking tools.
*   **Task 1.2:** Create `Containerfile.zeroclaw` (FROM the base image) that compiles and installs the ZeroClaw Rust binary.
*   **Task 1.3:** Create `Containerfile.forge` (FROM the zeroclaw image) to set up the Forge specific environment and dependencies.
*   **Task 1.4:** Update all orchestrator scripts to utilize `podman` in rootless mode instead of `docker`.

### Packet 2: Enclave & OneCLI Security Hardening
**Objective:** Wrap the OneCLI proxy in a hardware-backed enclave with TLS+CA and E2E signage.
*   **Task 2.1:** Compile and deploy the OneCLI Rust core inside the hardware-backed enclave.
*   **Task 2.2:** Implement an mTLS client in OneCLI. It must present a hardware-attested, CA-signed X.509 certificate to the central Vault to request secrets securely.
*   **Task 2.3:** Implement E2E Signage. Add an egress middleware to OneCLI that cryptographically signs all outgoing payload requests using the enclave's private key.

### Packet 3: Local Inference & Air-Gapped IPC
**Objective:** Secure local communication and model integration without network egress.
*   **Task 3.1:** Implement and verify ZeroClaw's SQLite-based file-polling (`inbound.db`/`outbound.db`) via Podman volumes for zero-egress IPC.
*   **Task 3.2:** Develop a Rust-based MCP server on the host connected to local inference containers.
*   **Task 3.3:** Map the host MCP server into the Fedora 44 Forge container via a local Unix socket (or strict localhost port-forward) to allow the Forge to list, find, and load models securely.

---

## Open-Ended Issues (For Worker Resolution & Expansion)
The following issues require further research and reduction by the worker agents. Workers must pick these up, use the `/meta-orchestration` skill to reduce uncertainty, and iteratively append concrete implementation tasks directly to this plan.

### Issue A: SELinux Policies for Fedora 44 Containers
*   **Context:** Both the Forge and ZeroClaw are running in Fedora 44 containers and require strong SELinux security profiles to prevent container escapes or unauthorized host access.
*   **Ambiguity:** We need to define exactly what permissions the ZeroClaw engine and Forge need, and generate customized SELinux profiles (`.te` / `.mod` / `.pp`) for Podman.
*   **Goal:** Research Podman SELinux integration and append concrete work tasks to build and enforce these policies.

### Issue B: Vault Dashboard & Observatorium Integration
*   **Context:** The Vault needs an accountability and secret-tracking dashboard. We want to evaluate minimalistic open-source dashboards and integrate them into our existing "Observatorium" web container.
*   **Ambiguity:** Which minimalistic dashboard is best suited for this? How do we route its UI securely through our web container?
*   **Goal:** Research open-source secret tracking dashboards, select one, and append tasks to integrate it into the Observatorium.

### Issue C: The Observability Triad (Code, Cheatsheets, Specs)
*   **Context:** We changed our traces implementation, but we must maintain robust observability across the triad of **Code**, **Cheatsheets**, and **Specs**. This ensures our iterative implementation remains monotonically convergent.
*   **Ambiguity:** How does the new traces implementation map exactly to cheatsheets and specs in the current architecture?
*   **Goal:** Research the integration points for the triad under the new tracing model and append tasks to build out the logging/tracing infrastructure in the Observatorium.
