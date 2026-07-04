# Forge agent permission defaults — pre-grant the ephemeral sandbox, enforce at the boundary

- **Date**: 2026-07-02
- **Host**: windows (windows-next), from the first interactive OpenCode forge session
- **Status**: research — feeds order 156
- **Operator questions** (verbatim intent): OpenCode prompted for permission to read `/etc`,
  `/tmp`, `/proc` and to touch `/home/forge/*`. Should those grants be needed at all? Should we
  make them accessible by default with fine-grained restrictions and SELinux?

## Position (recommended)

Inside the forge, agent-level permission prompts for the CONTAINER's own filesystem are
security theater: the forge is ephemeral, single-project, and already contained by the real
boundaries (enclave network + proxy allowlist, podman isolation, planned SELinux MCS in
Phase 6, git-mirror credential indirection — no raw GitHub token in the container). Prompting
the user to allow `/proc` reads trains them to click "allow" while adding no protection: the
process could read `/proc` regardless of what the agent-side policy says.

Default-grant in the forge agent configs (images/default/config-overlay/{opencode,claude,codex}):
- **read**: `/etc`, `/proc`, `/tmp`, `/usr`, `/opt` (introspection/diagnostics need these)
- **read+write**: `/home/forge/**` (toolchain configs, caches, project tree — operator: "since
  the forge is ephemeral it's safe to let agents play around with them")
- keep prompting (or deny) for: nothing filesystem-local; network egress is already governed by
  the proxy allowlist, not agent policy.

The real enforcement lives at the boundary and should be strengthened there, not in prompts:
SELinux labels for the forge domain (Phase 6), proxy allowlist, argv allowlist on the exec
chain (order 141 slice 5), mirror-mediated credentials.

## Notes from the same session (separate packets)

- `dubious ownership` on the mounted tree is git's `safe.directory` check tripping on
  uid mismatch (host-mounted tree vs forge uid 1000) — NOT certificate-related. Certs are fine
  (GitHub 200 via proxy with the combined CA). → order 157.
- `url.insteadOf` rewrite for the enclave push path wasn't installed
  (`rewrite_origin_for_enclave_push()` skipped); agent had to set it manually. → order 157.
- Mirror accepts pushes but has no upstream remote → commits trapped
  (`[git-mirror] No remote configured, skipping push`); agent-filed blocker:
  plan/issues/git-mirror-no-upstream-remote-2026-07-02.md. → order 158.
- Full capability baseline: plan/diagnostics/diagnostics_2026-07-02-summary.md (63 tools ✅,
  13 missing, 5 config gaps: LANG, JAVA_HOME, GOROOT, dangling FLUTTER_ROOT, insteadOf).

## Exit criteria (implementation slice)

- Forge OpenCode/Claude/Codex configs pre-grant the paths above; fresh forge session runs
  `/meta-orchestration`-class diagnostics with ZERO filesystem permission prompts.
- The boundary-enforcement story (proxy allowlist, SELinux plan, credential indirection) is
  written into the spec so "why default-grant is safe" is documented, not folklore.
- Prompts remain only where the boundary cannot enforce (if any such case is identified).
