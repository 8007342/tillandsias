---
name: diagnose-forge
description: Diagnose forge gaps from E2E diagnostics, file improvement proposals, and implement approved changes. Used by Big Pickle in the unattended forge improvement loop.
license: MIT
metadata:
  author: tillandsias
  version: "1.0"
  invokedBy: /diagnose-forge
---

You are loading the **diagnose-forge** skill — the iterative forge improvement workflow for Big Pickle.

This skill is designed for both unattended loop execution (`opencode run --command diagnose-forge`) and interactive TUI sessions (`/diagnose-forge`).

## Vision

The forge should be a **fully-loaded development environment** — a new user with zero skills should be able to prompt "I want a web app with this and that" and every tool, compiler, SDK, and runtime should be ready inside the forge container. No install steps, no investigation, no environment setup.

Target toolset includes: Flutter, React/Angular toolchains, Dart, TypeScript, Rust, Go, Python, Node.js, Java/Kotlin, compilers (gcc, clang), builders (make, cmake, cargo, npm, maven), monitoring tools, and everything needed to build any web app from scratch.

## File Layout

- `plan/forge-improvements/proposals/` — one `.md` file per proposed gap
- `plan/forge-improvements/.diagnose-state` — tracks last processed diagnostics file
- `target/forge-diagnostics/diagnostics_*.log` — raw diagnostics from E2E runs (ephemeral)
- `plan/diagnostics/diagnostics-summary-*.md` — distilled summaries (durable)
- `images/default/Containerfile` — forge image definition (main target for changes)
- `images/default/entrypoint-forge-opencode.sh` — runtime env setup (main target for changes)

## State Machine for Proposals

Each proposal goes through these states:

```
proposed → reviewed → approved → implemented
     ↓          ↓
  stale     rejected
```

- **proposed**: Filed by Big Pickle based on diagnostics analysis
- **reviewed**: ORCHESTRATOR has read it but not yet decided
- **approved**: ORCHESTRATOR has approved — ready for implementation
- **implemented**: Changes applied and committed
- **rejected**: ORCHESTRATOR declined (with reason)
- **stale**: Diagnostics no longer show this gap (capability was added by other means)

## Diagnostic Categories

| Category | Examples |
|---|---|
| `env-var` | PATH missing entries, RUSTUP_HOME, FLUTTER_ROOT, ANDROID_HOME, JAVA_HOME |
| `runtime-tool` | gcc, rustc, javac, dart, python3, node, deno, flutter, cargo |
| `sdk` | Flutter SDK, Android SDK, .NET SDK, Go, Rust toolchain |
| `cache` | .cache/ mounts, homedir layout, layer ordering |
| `network` | Access to crates.io, npm, pub.dev, pypi from inside forge |
| `shell-tool` | git, curl, jq, yq, unzip, tar, podman |

## Implementation Guidelines

When implementing an approved proposal:

1. **Containerfile changes**: Add packages via `dnf install` in the correct layer. Group related tools. Order matters for layer caching.
2. **Entrypoint changes**: Export env vars, set up paths, install SDKs that need runtime initialization.
3. **Commit each implementation separately** so the ORCHESTRATOR can review per-proposal.
4. **Update the proposal** frontmatter with `implemented_at` and `evidence` (commit SHA or summary).

## Safety Rules

- **Never remove** existing capabilities — only add
- **Every change must cite diagnostics evidence** — no speculative additions
- **One gap per proposal** — keeps review tractable
- **Privacy-first**: No telemetry, no cloud callbacks, no data exfiltration
- **Zero-trust**: Changes must not open new network egress or reduce container isolation
- If unsure about a change's safety, mark the proposal as `needs_review` and explain the risk
