---
title: Install socat for host-browser MCP stub bridge
gap: socat is referenced in the default-image spec for the host-browser MCP stub, but is not installed in the forge image
category: shell-tool
status: proposed
proposed_at: 2026-05-29T10:50:00Z
changes:
  - file: images/default/Containerfile
    description: Add `socat` to the microdnf install RUN layer. Required for the host-browser MCP stub to bridge stdio to the control socket.
approved_by: null
---

## Gap

The `default-image` spec (openspec/specs/default-image/spec.md, line 391) explicitly mentions socat:

> "The stub MAY be implemented as a shell script using `socat` and `printf`-based length prefixing if `socat` is reliably present in the forge image"

However, `socat` is not installed in the current Containerfile. The host-browser MCP stub will either silently fail at runtime or the image must rely on a Rust binary (~200 KB) as fallback. Installing socat (or verifying it's present) is required for the shell-based implementation path.

## Evidence

- `openspec/specs/default-image/spec.md` line 391: mentions socat as implementation option
- `images/default/Containerfile` lines 17-24: no socat package

## Safety

- `socat` is a standard Fedora Minimal package — no untrusted downloads.
- Minimal size impact (~200 KB).
- No credentials or secrets are involved.
