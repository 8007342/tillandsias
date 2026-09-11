---
name: forge-quick-intro
description: Jumpstarts an agent's awareness of the pre-configured Forge environment using a tiny amount of tokens.
---

# Forge Quick Intro

**Purpose:**
Immediately bootstrap a new agent's awareness of the Forge environment. Instead of wasting tokens exploring the environment to see what compilers, tools, or browsers are installed, agents should read this brief intro.

**The Forge Environment is fully loaded. You DO NOT need to install or search for these tools. They are ready to use:**
- **Compilers & Languages:** Rust, Cargo, Java (OpenJDK), Python 3, Node.js, Go, Dart, and Flutter.
- **Web & Browsers:** Headless and headful Chrome debugging browsers are pre-installed and configured.
- **Tools:** Git, GitHub CLI (`gh`), `curl`, `wget`, `jq`, `ripgrep`, `fd-find`, `bat`, `yq`, `just`, etc.
- **Package Manager:** `dnf` (`microdnf`) is available for additional packages if absolutely needed, though most dev tools are already present.
- **Safe Mode:** You are operating in a highly permissive "YOLO" environment designed for autonomous coding.
- **Ephemeral Architecture:** The project workspace is mounted inside the container at `/home/forge/src/<project>` on an ephemeral RAM tmpfs (`mode=0777`). The host filesystem is never touched (`HOST/src/<anything>` is never created).
- **Work Persistence:** The forge container and RAM tmpfs are completely ephemeral. Any uncommitted or unpushed work is permanently lost upon container exit or teardown. Always commit and push every change (`git push` routes to the mirror), and verify with `scripts/check-forge-findings-persisted.sh`.
- **Project status:** ask, don't grep — forge-plan MCP tools (`plan_answer`, `plan_next`, `plan_status`, `methodology_ask`, `spec_answer`) or Local Experts mode (grounded `expert-serve`). Check `.forge-startup-context.md`'s `experts_state` / `expert_capability` lines first; when degraded or unsupported, the `plan/` files are the recorded fallback.

**Directive:**
Assume all standard modern development tools are in your `PATH`. When instructed to "build an app" or "compile a project", proceed immediately to coding and executing rather than searching the file system for the compiler binary. Commit and push all progress before concluding your session.

