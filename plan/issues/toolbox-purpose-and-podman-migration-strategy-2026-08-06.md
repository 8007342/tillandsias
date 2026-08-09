# Developer Toolboxes Purpose and Podman Container Migration Strategy (v0.5)

- packet_id: toolbox-purpose-and-podman-migration-strategy
- order: 618-kjx8
- status: completed
- desired_release: v0.5
- host: linux_mutable (`macuahuitl`)
- filed_by: meta-orchestration (`linux-mutable-macuahuitl-gemini-20260806T1304Z`)

## Executive Summary

On Linux development hosts (both immutable distros like Fedora Silverblue and mutable hosts), **toolboxes** (via Toolbx / `podman`) serve as isolated, reproducible developer environments containing non-standard toolchains (e.g. cross-compilers, NPU drivers, specific Rust/C++ dependencies). They prevent system pollution and ensure developer tools can be installed on immutable filesystems.

This document synthesizes existing workspace architecture (OpenSpec, methodology, and empirical research notes) into a formal reference documenting:
1. **Toolbox Purpose**: Why local developer toolboxes are used during exploratory, NPU/GPU prototyping, and toolchain-heavy development.
2. **Podman Container Migration Strategy**: How work matured inside local toolboxes transitions into production-grade, rootless OCI Podman container workloads within the Tillandsias enclave stack.

---

## Part 1: Purpose of Developer Toolboxes

### 1.1 Development Isolation & Immutable Host Parity
- **Fedora Silverblue & Immutable Linux Support**: The host `/usr` filesystem is read-only (`rpm-ostree`). `toolbox create --container tillandsias-builder` provides a mutable Fedora environment sharing the user's `$HOME` where `dnf install` and `rustup` can run without modifying the host system.
- **Dependency & Toolchain Sandboxing**: Toolboxes allow installing experimental software (e.g., COPR packages, custom libraries, cross-compilers like `aarch64-linux-gnu-gcc`) without polluting the primary OS or conflicting with host packages.
- **Transparent Build Wrapper**: `scripts/with-tillandsias-builder.sh` automatically detects when execution occurs on an immutable host or when required build tools are missing, re-executing `./build.sh` commands seamlessly inside the designated `tillandsias-builder` toolbox.

### 1.2 Prototyping Hardware Acceleration (NPU/GPU)
- **Fast Hardware Exploration**: Local toolboxes allow rapid iteration on hardware acceleration runtimes (e.g., AMD XDNA2 NPU shims, FastFlowLM, Lemonade Server, Vulkan/ROCm driver user-space libraries) without requiring root host modifications.
- **Host Device Passthrough**: Toolboxes automatically share `/dev/dri`, `/dev/accel`, and GPU/NPU device nodes along with host systemd and user sockets, simplifying initial bring-up.

---

## Part 2: Podman Container Migration Strategy

While toolboxes are ideal for developer iteration, production execution requires fully isolated, reproducible OCI Podman containers within the Tillandsias enclave (`tillandsias-tillandsias-forge`, `tillandsias-inference`, `tillandsias-vault`, etc.).

### 2.1 Toolbox vs. Production Podman Container Matrix

| Feature | Developer Toolbx Container | Enclave Production Podman Container |
| :--- | :--- | :--- |
| **Mount Scope** | Full `$HOME` & XDG runtime directory mounted | Minimal, explicit volume mounts (isolated scratch/cache) |
| **User & PID Space** | Shared host PID namespace & host user environment | Isolated user namespace (`userns`), restricted PID space |
| **Container Image** | Dynamic `dnf` package installs on top of base Fedora | Immutable container image built from precise `Containerfile` |
| **Networking** | Shared host network namespace | Isolated CNI enclave network (`tillandsias-enclave`) |
| **Lifecycle** | Long-lived interactive state | Declarative, versioned lifecycle managed by `tillandsias-headless` |

### 2.2 Standard Migration Workflow

When moving a component (such as an local NPU/GPU RAG inference engine) from a local toolbox to the Tillandsias container stack, agents must follow this 4-step migration protocol:

#### Step 1: Immutable Containerfile Definition
- Replace dynamic `dnf install` steps executed in the toolbox with explicit `Containerfile` build instructions under `images/<component>/Containerfile`.
- Pin base image tags (e.g., `registry.fedoraproject.org/fedora:44`).
- Eliminate host `$HOME` dependencies by embedding necessary configuration defaults directly in the image or injecting them via enclave secrets.

#### Step 2: Namespace & Security Decoupling
- Remove host PID sharing (`--pid=host`) and host filesystem mounts.
- Configure explicit device passthrough (e.g., `--device /dev/accel/accel0` or GPU passthrough flags) in the container specification (`crates/tillandsias-podman`).
- Ensure rootless compatibility: test under rootless Podman without requiring `sudo` or unconfined SELinux privileges (`spc_t`).

#### Step 3: Enclave Integration
- Register the container in `crates/tillandsias-headless` and `crates/tillandsias-podman`.
- Connect the container to the internal Tillandsias enclave reverse proxy and secret vault rather than listening directly on host ports.
- Implement structured health checks and liveness probes.

#### Step 4: Verification & Litmus Gating
- Author an instant/full litmus test in `openspec/litmus-tests/` validating container startup, device accessibility, and IPC endpoints.
- Run `./build.sh --check` to ensure trace traceability (`@trace spec:...`) and ledger integrity.

---

## Part 3: Verification & Provenance

- **Methodology Reference**: `methodology/multi-host-development.yaml` (section `fedora_silverblue_immutable_builders`).
- **Empirical Research Findings**: `plan/issues/npu-container-citizenship-e2e-2026-07-29.md` (validated that FastFlowLM and Lemonade NPU runtimes achieved 100% performance parity when migrated from toolboxes to rootless OCI Podman containers).
- **Toolbox Implementation**: `scripts/with-tillandsias-builder.sh` & `plan/issues/silverblue-toolbox-builder-2026-07-07.md`.

---
*Created by Antigravity Meta-Orchestration on macuahuitl (linux_mutable) for v0.5 release track.*
