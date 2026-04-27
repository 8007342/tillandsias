# Cheatsheets Index

All cheatsheets are curated references for tools and languages available in the Tillandsias forge container. Each entry is ≤200 lines, scannable in <30 seconds, organized by use-case category. Read from inside the forge via `cat $TILLANDSIAS_CHEATSHEETS/INDEX.md` or `cat $TILLANDSIAS_CHEATSHEETS/INDEX.md | rg <topic>`.

## runtime

- `forge-container.md` — Forge container runtime: Fedora 43, mutable/immutable boundaries, console scripts, overlays
- `runtime-limitations.md` — RUNTIME_LIMITATIONS_NNN.md format: reporting missing tools back to the host
- `networking.md` — Enclave network isolation: proxy, git mirror, inference service (ollama)

## agents

- `claude-code.md` — Claude Code CLI: launching, model flags, hooks, skills, MCP
- `opencode.md` — OpenCode CLI + web mode: serve, sessions, config, parallel agents
- `openspec.md` — OpenSpec workflow: new/instructions/validate/status/archive

## languages

- `python.md` — Python 3: syntax, types, dataclasses, asyncio, stdlib
- `rust.md` — Rust: ownership, borrowing, async, cargo
- `java.md` — Java 21 LTS: records, sealed classes, pattern matching, streams
- `typescript.md` — TypeScript: type inference, generics, utility types, tsconfig
- `javascript.md` — Modern JavaScript: ES2023 syntax, async/await, arrays, modules
- `bash.md` — Bash: strict mode, parameter expansion, quoting, control flow
- `dart.md` — Dart 3: null safety, classes, mixins, async, streams
- `sql.md` — SQL: SELECT, JOINs, window functions, CTEs, transactions
- `json.md` — JSON: syntax, pitfalls, JSON Lines, JSON Pointer
- `yaml.md` — YAML 1.2: indentation, anchors, multi-line strings, common pitfalls
- `toml.md` — TOML 1.0: tables, arrays-of-tables, dotted keys, vs JSON/YAML
- `html.md` — HTML5: semantic tags, ARIA, forms, block vs inline
- `css.md` — Modern CSS: flexbox, grid, custom properties, specificity
- `markdown.md` — CommonMark + GFM: syntax, tables, code blocks, GitHub extensions
- `xml.md` — XML: namespaces, XPath basics, when to use vs JSON/YAML

## utils

[Will be populated by Wave C sub-agents]

## build

[Will be populated by Wave D sub-agents]

## web

[Will be populated by Wave E sub-agents]

## test

[Will be populated by Wave E sub-agents]
