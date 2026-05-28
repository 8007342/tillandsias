---
name: multihost-orchestration
description: Trigger and execute the Tillandsias multi-host coordination loop to reconcile plans, track metrics, and unblock agents across Linux, Windows, and macOS.
---

# Multi-Host Orchestration

This skill acts as the primary entry point for scheduled orchestration runs (e.g., via Antigravity or other provider frameworks). It delegates the core coordination logic to the specialized `coordinate-multihost-work` skill.

## Trigger Instructions

When an agent triggers this skill (hourly or daily), the agent MUST:

1.  **Activate Orchestration Context**: Acknowledge the request to perform multi-host orchestration.
2.  **Execute Coordination**: Follow the full procedure defined in the project-level `./skills/coordinate-multihost-work/SKILL.md`.
    -   **Fetch & Sync**: Pull the latest `linux-next` ledger.
    -   **Audit Metrics & Active Conflicts**: Compute blocker trees and detect concurrent deadlocks or divergence.
    -   **Calculate Velocity**: Track the current convergence velocity ($\mathcal{V}_c$) and enforce the finite-time convergence guarantee.
    -   **Shape, Mediate & Assign**: Resolve active thrashes or mutual waits, and distribute clear, actionable primary and fallback waves to Linux, Windows, and macOS hosts.
    -   **Integrate & Validate**: Merge sibling platform branches and run the runtime litmus as required.
3.  **Checkpoint**: Commit and push all coordination updates back to `origin/linux-next` using the plan-write discipline.
4.  **Report**: Provide the standard `LastExecutionTime`, blocker summary, convergence velocity status, and active mediation results.
