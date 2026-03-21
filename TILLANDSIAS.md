# TILLANDSIAS.md

**Project Bootstrap Specification for /opsx-new**

---

# 🌿 Tillandsias

*A lightweight, ephemeral, local-first system that turns ideas into runnable software.*

---

# 1. Vision

Tillandsias is a **cross-platform, tray-based application** that enables users to:

* Create applications from simple intent (e.g. “build a web tetris clone”)
* Run them locally with one click
* Optionally deploy them elsewhere (future scope)

The system is:

* **Ephemeral by design** → everything can be destroyed safely
* **Self-contained** → minimal host dependencies
* **Opinionated** → optimized for beginner success
* **Invisible** → hides all infrastructure complexity

The user never sees:

* containers
* kubernetes
* runtimes
* git

They only see:

* **Create**
* **Work**
* **Run**
* **Stop**

---

# 2. Core Principles

## 2.1 Ephemeral Everything

* All environments are disposable
* Rebuildable at any time
* No hidden persistent state beyond caches

## 2.2 Local-First

* Works fully offline after initial setup
* Uses local hardware
* No required cloud dependency

## 2.3 Idempotent Execution

* Same input → same result
* Re-running never corrupts state

## 2.4 Zero Cognitive Load UX

* No technical jargon exposed
* No configuration required for MVP workflows

## 2.5 Safety by Default

* All user code treated as **untrusted**
* Isolation enforced at runtime layer
* Host system remains protected

---

# 3. High-Level Architecture

```text
Tauri Tray App (Rust)
        ↓
Podman (host runtime)
        ↓
Forge Environment (ephemeral container)
        ↓
Generated Artifacts (container definitions)
        ↓
Runtime Containers (isolated execution)
```

---

# 4. Components

## 4.1 Tray Application (Tauri + Rust)

### Responsibilities

* System tray UI
* Filesystem scanning (`~/src`)
* Lifecycle orchestration
* Process management
* Minimal resource usage (idle ~0%)

### Requirements

* Written in Rust
* Built with Tauri
* Cross-platform:

  * Linux
  * macOS
  * Windows

### Performance Goals

* Idle CPU: ~0%
* Memory: minimal (<100MB target)
* Instant UI response

---

## 4.2 Forge Environment

### Definition

An ephemeral container that:

* Uses **Fedora Minimal**
* Installs **Nix (single-user mode)**
* Provides curated dev tools:

  * node
  * python
  * httpd
  * mysql/postgres
  * react/flutter toolchains

### Behavior

* Created on demand
* Destroyed after use
* Uses shared cache directories:

  * `~/.cache/tillandsias/nix`
  * `~/.cache/tillandsias/containers`

### Purpose

* Build applications
* Output runnable artifacts

---

## 4.3 Artifact System

Forge outputs:

* Container definitions
* Runtime configs
* Metadata describing how to run the app

Example (conceptual, not exposed to user):

```text
~/src/project/
  tillandsias/
    app.yaml
    containers/
    runtime/
```

---

## 4.4 Runtime Execution

The tray app detects artifacts and allows:

* Start
* Stop
* Destroy

Execution modes:

* Local container (default)
* Future: cluster / cloud

---

# 5. UX Specification

## 5.1 Tray Interaction

### Root Menu

```text
Tillandsias
  ├─ ~/src/
  │    ├─ project-a/
  │    │     ├─ Work Here
  │    │     ├─ Start (if artifacts exist)
  │    │     └─ Stop
  │    └─ project-b/
  │
  ├─ Running
  │    ├─ app-1 🌸 Stop | Destroy (hold 5s)
  │    └─ app-2 🌸 Stop | Destroy (hold 5s)
```

---

## 5.2 Project Menu

For each project:

* **Work Here**

  * Launches Forge environment
* **Start**

  * Runs detected runtime
* **Stop**

  * Stops runtime

---

## 5.3 Running Apps

* Displayed in tray
* Each has:

  * 🌸 Tillandsia icon
  * Stop button
  * Destroy (hold 5 seconds)

---

## 5.4 Icon Behavior

| State            | Icon               |
| ---------------- | ------------------ |
| Idle             | Minimal Tillandsia |
| Project detected | Subtle bloom       |
| Running apps     | Colorful flowers   |
| Multiple apps    | Multiple blooms    |

---

# 6. Visual Identity

## Theme: Tillandsias

* Air plants → no roots → host-independent
* Bloom → create → propagate → fade

### Iconography

* Primary: **Tillandsia Aeranthos**
* Secondary: **Caput-Medusae**
* Styles:

  * Full color (desktop)
  * Black/White (light mode)
  * White/Black (dark mode)

---

# 7. Runtime Strategy

## 7.1 Default

* Rootless Podman containers

## 7.2 Isolation Levels (future)

* Standard container (fast path)
* VM-backed (secure mode)
* MicroVM (hostile workloads)

---

# 8. Filesystem Model

### Input

```text
~/src/<project>
```

### Internal

```text
~/.cache/tillandsias/
  ├─ nix/
  ├─ containers/
  ├─ runtime/
```

### Rules

* No global system pollution
* All state reproducible
* Safe to delete cache

---

# 9. Data & IPC

Use:

* Rust-native serialization (avoid Protobuf)
* Prefer:

  * **bincode** or
  * **postcard** or
  * **rkyv** (zero-copy)

Goal:

* minimal overhead
* fast IPC between components

---

# 10. Security Model

## Trust Zones

| Component | Trust     |
| --------- | --------- |
| Tray App  | Trusted   |
| Forge     | Untrusted |
| User Code | Hostile   |

## Enforcement

* Containers isolated from host
* Limited filesystem mounts
* No direct access outside project scope
* Optional SELinux support (Linux)

---

# 11. Initial Scope (MVP)

### Supported Use Case

* Web applications:

  * Node / React
  * Python / Flask
  * Static sites
  * Simple DB-backed apps

### Goals

* From zero → running app in minutes
* No configuration
* Fully local

---

# 12. Non-Goals (for now)

* Full Kubernetes integration
* Cloud orchestration
* Advanced debugging UI
* Multi-user systems

---

# 13. Development Plan

## Phase 1

* Tauri tray app
* Filesystem scanning
* Basic menu

## Phase 2

* Podman integration
* Forge launch

## Phase 3

* Artifact detection
* Runtime execution

## Phase 4

* UX polish
* Icon states
* Performance tuning

---

# 14. Naming

* App: **Tillandsias**
* Internal theme: Aeranthos ecosystem
* No technical terms exposed to user

---

# 15. Final Goal

A system where:

> A user right-clicks → types an idea → runs a working application
> safely, locally, reproducibly

No setup. No knowledge required.

---

# 16. Conclusion

Tillandsias is not a dev tool.

It is:

> **a quiet system that makes software appear**

* ephemeral like a bloom
* portable like air
* safe for beginners
* powerful enough for experts

The tray icon is the only visible surface.
Everything else happens invisibly, correctly, and reproducibly.

---

**Bootstrapping Directive**

Initialize a Rust + Tauri project implementing:

* Tray-only UI
* Filesystem watcher (`~/src`)
* Podman command execution layer
* Modular architecture for Forge + Runtime
* Cross-platform builds (Linux/macOS/Windows)

Focus first on:

* correctness
* minimalism
* responsiveness

Everything else evolves from there.

---
