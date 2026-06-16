---
title: Install additional dev tools (tokei, hyperfine, sd, wasm-opt)
gap: "missing_tools: tokei, hyperfine, sd, wasm-opt — code statistics, benchmarking, sed alternative, WASM optimization"
category: runtime-tool
status: proposed
proposed_at: 2026-06-16T08:00:00Z
changes:
  - file: images/default/Containerfile
    description: |
      Install tokei (cargo install), hyperfine (cargo install or microdnf),
      sd (cargo install), wasm-opt (microdnf binaryen or npm).
---

## Gap

Diagnostics (`diagnostics_20260614T062505Z-summary.md`,
`diagnostics_20260614T160501Z-summary.md`,
`diagnostics_20260614T220511Z-summary.md`) report these additional tools:

- **tokei**: Code statistics (lines of code, languages)
- **hyperfine**: Command-line benchmarking
- **sd**: Modern `sed` alternative with intuitive syntax
- **wasm-opt**: WebAssembly optimization from Binaryen

## Privacy/Isolation Assessment

- tokei, hyperfine, sd: cargo install — same envelope as existing Rust tooling
- wasm-opt: microdnf binaryen or npm install
- All local executables; no daemon, no root
- **Safe within the existing privacy/isolation envelope**
