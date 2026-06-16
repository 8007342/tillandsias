---
title: Install protobuf tooling (protoc, buf, grpcurl)
gap: "missing_tools: protoc, buf, grpcurl — protobuf compilation, linting, and gRPC debugging"
category: runtime-tool
status: proposed
proposed_at: 2026-06-16T08:00:00Z
changes:
  - file: images/default/Containerfile
    description: |
      Install protoc (protobuf compiler) via microdnf, and install buf
      (protobuf linter/language server) and grpcurl (gRPC CLI) from
      upstream releases.
---

## Gap

Multiple diagnostic runs (`diagnostics_20260603T044258Z-summary.md`,
`diagnostics_20260603T192817Z-summary.md`,
`diagnostics_20260603T220627Z-summary.md`,
`diagnostics_20260614T062505Z-summary.md`,
`diagnostics_20260614T160501Z-summary.md`) report missing protobuf tooling.

The project uses protobuf definitions (visible in the repo). Without `protoc`,
agents cannot regenerate Go/Rust protobuf bindings. `buf` provides modern
protobuf linting and breaking-change detection. `grpcurl` enables gRPC API
debugging from the command line.

## Evidence

- Reported in 5+ diagnostics files
- `missing_tools` consistently includes `protoc`, `buf`, `grpcurl`
- Project contains `.proto` files

## Privacy/Isolation Assessment

- protoc installed via microdnf — same envelope as existing toolchain
- buf is a single static Go binary — download from GitHub releases at build time
- grpcurl is a single static Go binary — download from GitHub releases at build time
- No daemon, no root, no new network egress
- **Safe within the existing privacy/isolation envelope**
