---
title: Install additional developer tools (pip3, poetry, gopls, gdb, lldb, strace, valgrind, yarn, pnpm, dart, flutter)
gap: "distilled summary diagnostics_20260528T120919Z reports extended missing tool list"
category: runtime-tool
status: proposed
proposed_at: 2026-05-28T12:15:00Z
changes:
  - file: images/default/Containerfile
    description: |
      Install additional developer tools as microdnf packages where available:
      - pip3 (python3-pip), poetry (pip install)
      - gopls (go install)
      - gdb, lldb, strace, valgrind (microdnf)
      - yarn, pnpm (npm install -g)
      - dart, flutter (tarball installation in /opt or ~/)
    - Note: flutter SDK is large (~1GB) — consider separate overlay image.
  - file: images/default/entrypoint-forge-opencode.sh
    description: Export DART_ROOT, FLUTTER_ROOT and add to PATH if flutter/dart installed.
approval_required: orchestrator
approved_by:
---

## Gap

The latest distilled summary (`diagnostics_20260528T120919Z-summary.md`) reports
additional missing tools beyond the raw log's analysis, including:
`pip3`, `poetry`, `gopls`, `gdb`, `lldb`, `strace`, `valgrind`, `yarn`, `pnpm`,
`gradle`, `kotlin`, `dart`, `flutter`, `rustup`.

These tools enable debugging (gdb, lldb, strace, valgrind), polyglot package
management (pip3, poetry, yarn, pnpm), and cross-platform mobile/web SDKs
(dart, flutter).

## Evidence

From `plan/diagnostics/diagnostics_20260528T120919Z-summary.md`:

- `Missing tools` section includes: pip3, poetry, pyright, gopls, gdb, lldb,
  strace, valgrind, yarn, pnpm, gradle, kotlin, dart, flutter, rustup
- Completeness: 21/25 checks passed (84%)

## Privacy / Isolation Assessment

- Most tools install via system packages (microdnf) or language-specific
  package managers within the forge sandbox.
- Flutter/dart SDKs would download via proxy; install targets are under
  `/opt/` or `/home/forge/` with no host contamination.
- Debuggers (gdb, lldb, strace, valgrind) operate within the existing
  `--cap-drop=ALL` and `--security-opt=no-new-privileges` constraints.
- **Safe within the existing privacy/isolation envelope.**
