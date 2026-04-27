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

- `git-workflows.md` — Git: cloning, committing, branching, rebasing, pushing (via enclave mirror)
- `gh-cli.md` — GitHub CLI: PRs, issues, workflows, auth (read-only outside forge)
- `jq-yq-json.md` — jq and yq: JSON/YAML querying, filtering, transformation
- `curl-http.md` — curl and wget: HTTP requests, downloads, API testing, proxies
- `rg-fd-search.md` — ripgrep and fd: fast code search and file finding
- `fzf-picker.md` — fzf: interactive fuzzy selection from piped input
- `podman-containers.md` — Podman: running, building, pushing containers and images
- `ssh-remote.md` — SSH and rsync: remote connections, secure file transfer, port forwarding

## build

- `cargo.md` — Cargo: build/test/check/clippy/fmt, workspaces, features, profiles
- `npm.md` — npm: install/run/publish scripts, package.json, workspaces
- `pnpm.md` — pnpm: install/run, workspaces, filtering, storage efficiency
- `yarn.md` — Yarn: classic vs berry, install/run, workspaces, resolutions
- `pip.md` — pip: install, requirements.txt, constraints, editable installs
- `pipx.md` — pipx: isolated tool installation, inject, --python versions
- `uv.md` — uv: fast pip replacement, lockfiles, project mode
- `poetry.md` — Poetry: init/add/build/publish, vs pip+venv, lock files

## web

- `protobuf.md` — Protocol Buffers: proto3 syntax, field numbers, well-known types, codegen
- `grpc.md` — gRPC: services, unary/streaming RPCs, gRPC-Web, client invocation
- `openapi.md` — OpenAPI 3.x: spec structure, schemas, security schemes, codegen
- `http.md` — HTTP/1.1 and HTTP/2: methods, status codes, headers, idempotency
- `websocket.md` — WebSocket protocol: framing, handshake, common libraries by language
- `sse.md` — Server-Sent Events: format, reconnection, text/event-stream, vs WebSocket

## test

- `pytest.md` — pytest: discovery, fixtures, parametrize, conftest, markers
- `junit.md` — JUnit 5 Jupiter: @Test, @BeforeEach, parametrized tests, assertions
