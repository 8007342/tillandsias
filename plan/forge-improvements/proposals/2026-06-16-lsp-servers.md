---
title: Install additional LSP servers (yaml-language-server, bash-language-server, lua-language-server, taplo)
gap: "missing_tools: yaml-language-server, bash-language-server, lua-language-server, taplo — LSP coverage gaps for YAML, shell, Lua, and TOML files"
category: runtime-tool
status: proposed
proposed_at: 2026-06-16T08:00:00Z
changes:
  - file: images/default/Containerfile
    description: |
      Install yaml-language-server, bash-language-server, and lua-language-server
      via npm install -g. Install taplo (TOML LSP) from GitHub releases.
---

## Gap

Multiple diagnostic runs (`diagnostics_20260604T002348Z-summary.md`,
`diagnostics_20260614T160501Z-summary.md`,
`diagnostics_20260614T180458Z-summary.md`) report missing LSP servers for
common file types used in the project:

- **yaml-language-server**: YAML files (OpenSpec, methodology, plan, CI configs)
- **bash-language-server**: Shell scripts (extensive shell usage in project)
- **lua-language-server**: Lua files (config files, tooling)
- **taplo**: TOML files (Rust/Cargo configuration, Python pyproject.toml)

The project uses all four file formats extensively. Without these LSP servers,
agents lack code intelligence (completion, diagnostics, hover) for these files.

## Evidence

- Reported in 3+ diagnostics files
- `missing_tools` includes yaml-language-server, bash-language-server,
  lua-language-server, taplo across multiple runs
- Project has extensive YAML, shell, Lua, and TOML files

## Privacy/Isolation Assessment

- yaml-language-server, bash-language-server, lua-language-server installed via
  npm — same envelope as existing node/npm
- taplo is a single static Rust binary
- No daemon, no root, no new network egress
- **Safe within the existing privacy/isolation envelope**
