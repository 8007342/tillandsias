---
name: forge-continuous-enhancement
description: Iteratively enhance the forge container and environment by running diagnostics, building, and committing changes autonomously.
---

# Forge Continuous Enhancement

**Purpose:**
This skill runs inside the forge to improve the forge itself iteratively. By capitalizing on the safe YOLO-mode environment (highly permissive settings for opencode and codex/claude), agents can confidently apply enhancements, test build outputs, measure telemetry (like build times and download sizes), and push commits back to the remote.

**Workflow:**
1. Execute inside the `tillandsias` codebase (e.g., via `tillandsias --opencode --prompt "Use the /forge-continuous-enhancement skill"`).
2. Review the build output logs from previous `Containerfile` builds (e.g. `build-install.log` or telemetry logs) to identify warnings, errors, and unoptimized layers.
3. Migrate manual `curl` installers and `tar/gz` manipulations in `images/default/Containerfile` to native `dnf` / `microdnf` package installs where possible.
4. Integrate telemetry to measure install times and download sizes during image builds, saving the output in the dev environment for further analysis.
5. Do NOT apply changes or push directly to `main`. Instead, file your findings, bugs, and enhancement proposals as work packets into the `./plan/issues/` directory.
6. Commit the issue reports to the appropriate host branch (`linux-next`, `osx-next`, or `windows-next`). These issues will be picked up and executed by future agents running the `/advance-work-from-plan` skill.

**Pre-requisites:**
- Opencode/Codex/Claude permission files must be loaded in YOLO mode (near full permissiveness).
- Telemetry logging must be available in the development environment for build output analysis.
