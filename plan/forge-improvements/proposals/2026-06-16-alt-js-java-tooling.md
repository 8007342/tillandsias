---
title: Install alternative JS runtimes & Java tooling (deno, bun, gradle)
gap: "missing_tools: deno, bun, gradle — alternative JavaScript runtimes and Java build tool"
category: runtime-tool
status: proposed
proposed_at: 2026-06-16T08:00:00Z
changes:
  - file: images/default/Containerfile
    description: |
      Install deno and bun via their standard install scripts (curl piped to
      shell). Install gradle via microdnf or SDKMAN. Note: deno and bun add
      significant image size.
---

## Gap

Diagnostic runs (`diagnostics_20260604T002348Z-summary.md`,
`diagnostics_20260614T062505Z-summary.md`,
`diagnostics_20260614T230648Z-summary.md`) report missing JS runtimes and
Java build tooling:

- **deno**: Modern TypeScript/JavaScript runtime
- **bun**: Fast JavaScript runtime and package manager
- **gradle**: Java build tool (complementary to existing maven)

## Privacy/Isolation Assessment

- deno/bun: single static binaries; significant image size impact
- gradle: SDKMAN or microdnf install
- deno has network permission model but respects existing proxy
- **Safe within the existing privacy/isolation envelope; size budget review needed**
