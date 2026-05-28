---
name: multihost-orchestration
description: Trigger and execute the Tillandsias multi-host coordination loop to reconcile plans, track metrics, and unblock agents across Linux, Windows, and macOS.
---

# Multi-Host Orchestration

This skill acts as the primary entry point for scheduled orchestration runs (e.g., via Antigravity). It delegates the core coordination logic to the specialized `coordinate-multihost-work` skill.

## Trigger Instructions

When Antigravity triggers this skill (hourly or daily), the agent MUST:

1.  **Activate Orchestration Context**: Acknowledge the request to perform multi-host orchestration.
2.  **Execute Coordination**: Follow the full procedure defined in `.codex/skills/coordinate-multihost-work/SKILL.md`.
    -   **Fetch & Sync**: Pull the latest `linux-next` ledger.
    -   **Audit Metrics**: Calculate work items, block durations, and the blocking tree (prioritizing root blockers).
    -   **Shape & Assign**: Distribute work waves to Linux, Windows, and macOS hosts.
    -   **Integrate & Validate**: Merge sibling branches and run the runtime litmus as required.
3.  **Checkpoint**: Commit and push all coordination updates back to `origin/linux-next`.
4.  **Report**: Provide the standard `LastExecutionTime` and blocker summary as required by the methodology.
