# Codex Forge Defaults: Full-Auto / No Permission Prompts Inside The Forge

**Filed**: 2026-07-04T02:16Z
**Origin**: forge meta-orchestration validation cycle
**Host**: forge container, linux-next
**Classification**: enhancement/bug-fix

## Observation

During this forge validation cycle, Codex prompted for permission escalation for
ordinary forge work:

- `git fetch`
- `git merge --ff-only`
- `cargo check`
- `cargo build`
- `git add` / `git commit`
- `git push`

Inside the forge, these prompts are noise. The forge is already the containment
boundary: it is an ephemeral project container with controlled mounts, proxy
egress, mirror-mediated git, and planned SELinux hardening. Agent prompts for
normal build, git, and filesystem operations do not add meaningful security, and
they slow down unattended `/meta-orchestration` loops.

## Desired Default

When `TILLANDSIAS_HOST_KIND=forge`, Codex should run in full-auto / YOLO mode by
default:

- no approval prompts for reading or writing within `/home/forge/src/**`;
- no approval prompts for writing forge-owned caches such as
  `/home/forge/.cache/tillandsias-project/**`;
- no approval prompts for normal build/test commands (`cargo check`, `cargo
  build`, `cargo test`, `./build.sh` when eligible);
- no approval prompts for normal git operations in the mounted project (`fetch`,
  `merge --ff-only`, `add`, `commit`, `push`);
- destructive substrate operations are governed by Tillandsias e2e preflight and
  `TILLANDSIAS_DESTRUCTIVE_RESET_OK`, not by Codex UI prompts inside the forge.

This must not weaken the host credential boundary. Full-auto applies to the
forge's own filesystem and command execution, not to importing host credentials.

## Expected Config Surface

Host agents should locate Codex's in-forge config overlay and set the equivalent
of:

- approval policy: never / no prompts
- sandbox mode: full workspace or danger-full-access inside the forge container
- command execution: allow normal build/git/test commands without user approval
- filesystem: allow `/home/forge/src/**`, `/home/forge/.cache/**`, `/tmp/**`

The exact file path should be discovered in the current image/config overlay
rather than guessed. Candidate areas mentioned by existing plan language include
`images/default/config-overlay/{opencode,claude,codex}`.

## Exit Criteria

- Fresh Codex forge session runs `/meta-orchestration` without prompting for
  ordinary git/build/filesystem approvals.
- `TILLANDSIAS_HOST_KIND=forge` is sufficient to select the full-auto profile.
- Non-forge Codex sessions keep their normal approval/sandbox posture.
- A regression litmus proves a simulated forge Codex config contains the
  no-prompt/full-auto settings.
- Documentation or in-forge diagnostics state that full-auto is safe because the
  forge container is the boundary, while host credentials remain quarantined.

## Related Existing Packet

Order 165 (`forge-agent-permission-defaults`) covers broader agent filesystem
permission defaults. This packet is Codex-specific because this cycle observed
Codex itself prompting for tool approval in the forge, including commands needed
to validate and commit the plan.
