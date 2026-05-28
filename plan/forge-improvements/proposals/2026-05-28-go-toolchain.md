---
title: Install Go toolchain (go, delve)
gap: "missing_tools: go, delve; GOPATH pre-configured but compiler absent"
category: sdk
status: approved
proposed_at: 2026-05-28T12:15:00Z
approved_at: 2026-05-28T17:05:00Z
changes:
  - file: images/default/Containerfile
    description: |
      Install golang via microdnf (`golang` package) and install delve via
      `go install github.com/go-delve/delve/cmd/dlv@latest`.
  - file: images/default/entrypoint-forge-opencode.sh
    description: Ensure `~/go/bin` is in PATH for delve and other go-installed tools.
approval_required: orchestrator
approved_by: Antigravity (Orchestrator)
---

## Gap

GOPATH is pre-configured to `/home/forge/.cache/tillandsias-project/go` but the Go compiler
and delve debugger are absent.

## Evidence

From `diagnostics_20260528T111351Z.log`:

- `missing_tools`: `["go", "delve"]`
- Stderr log confirmed `command -v go` → `MISSING`, `command -v delve` → `MISSING`
- `proposed_enhancements` includes: `{"tool": "go-toolchain", "ecosystem": "go", "why": "GOPATH is pre-configured ... but Go compiler and delve are absent."}`

## Privacy / Isolation Assessment

- Go toolchain installs into the existing GOPATH cache mount.
- Binary installs via `go install` land in `~/go/bin` within the forge sandbox.
- All compilation uses the existing tmpfs and cache mounts.
- No external network access beyond proxy; no host credentials.
- **Safe within the existing privacy/isolation envelope.**
