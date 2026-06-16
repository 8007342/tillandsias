---
name: forge-continuous-enhancement
description: Iteratively enhance the forge container and environment by running diagnostics, building, and committing changes autonomously.
---

# Forge Continuous Enhancement

**Purpose:**
This skill runs inside the forge to improve the forge itself iteratively. By capitalizing on the safe YOLO-mode environment (highly permissive settings for opencode and codex/claude), agents can confidently inspect diagnostics, shape proposals, claim approved plan packets, test build outputs, measure telemetry, and push durable plan or implementation checkpoints.

**Workflow:**
1. Execute inside the `tillandsias` codebase (e.g., via `tillandsias --opencode --prompt "Use the /forge-continuous-enhancement skill"`).
2. Review the build output logs from previous `Containerfile` builds (e.g. `build-install.log` or telemetry logs) to identify warnings, errors, and unoptimized layers.
3. If no approved plan packet exists, do NOT apply product changes. File findings, bugs, and enhancement proposals under `./plan/issues/` or `plan/forge-improvements/proposals/`.
4. If an approved packet exists, claim it through `/advance-work-from-plan` discipline before editing implementation files.
5. Do NOT push directly to `main`.
6. Commit and push issue reports, proposals, or claimed implementation checkpoints before exit.

**Pre-requisites:**
- Opencode/Codex/Claude permission files must be loaded in YOLO mode (near full permissiveness).
- Telemetry logging must be available in the development environment for build output analysis.
