# Cheatsheets Index

All cheatsheets are curated references for tools and languages available in the Tillandsias forge container. Each entry is ≤200 lines, scannable in <30 seconds, organized by use-case category. Read from inside the forge via `cat $TILLANDSIAS_CHEATSHEETS/INDEX.md` or `cat $TILLANDSIAS_CHEATSHEETS/INDEX.md | rg <topic>`.

## runtime

- `forge-container.md` — Forge container runtime: Fedora 43, mutable/immutable boundaries, console scripts, overlays
- `runtime-limitations.md` — RUNTIME_LIMITATIONS_NNN.md format: reporting missing tools back to the host
- `networking.md` — Enclave network isolation: proxy, git mirror, inference service (ollama)
- `logging-levels.md` — Log levels (TRACE/DEBUG/INFO/WARN/ERROR), CLI flags, environment variables, accountability windows
- `windows-event-viewer.md` — Windows Event Log integration: viewing events, PowerShell queries, manual registration

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
- `cargo-test.md` — Rust test discovery, integration tests, doctests, benchmarks
- `go-test.md` — Go testing: -run flag, table-driven tests, helpers, benchmarks
- `selenium.md` — Selenium WebDriver: browser automation, waits, best practices
- `playwright.md` — Playwright: cross-browser testing, auto-install, fixtures

## architecture

- `event-driven-basics.md` — Event-driven patterns, async message passing, reactor model
- `reactive-streams-spec.md` — Reactive Streams: publishers, subscribers, backpressure

## build (continued)

- `gradle.md` — Gradle 8.x: tasks, dependencies, wrapper, Kotlin DSL basics
- `maven.md` — Maven: lifecycle phases, plugins, dependency management, profiles
- `go.md` — Go modules: init, tidy, get; build/test/run; GOPATH vs module mode
- `flutter.md` — Flutter 3.24: pub get, run --device-id, build (web/desktop only)
- `make.md` — GNU make: rules, variables, .PHONY, recipes, common pitfalls
- `cmake.md` — CMake 3.x: project setup, target definitions, find_package, generators
- `ninja.md` — Ninja build system: build.ninja format, when to use vs make
- `nix-flake-basics.md` — Nix flakes: inputs, outputs, derivations for reproducible builds
- `distro-packaged-cheatsheets.md` — Distribution-specific packaging (Fedora rpms, Debian debs)

## languages (continued)

- `java.md` — Java 21 LTS (in `java/` subdirectory)
  - `java/rxjava-event-driven.md` — RxJava reactive streams: observables, operators, threading

## data

- `postgresql-indexing-basics.md` — PostgreSQL indexes: B-tree, BRIN, GiST, partial indexes

## security

- `owasp-top-10-2021.md` — OWASP Top 10 vulnerabilities: injection, auth, XSS, crypto

## privacy

- `data-minimization-gdpr.md` — GDPR compliance: data minimization, consent, retention

## algorithms

- `binary-search.md` — Binary search: sorted array lookup, boundary conditions, variations

## patterns

- `gof-observer.md` — Gang of Four Observer pattern: subjects, observers, notifications

## runtime (continued)

- `cheatsheet-architecture-v2.md` — Cheatsheet versioning, curation layers, tiered access
- `cheatsheet-tier-system.md` — Three-tier cheatsheet access: CORE (always available), HOSTED (curated), EXTERNAL (agent-reported)
- `cheatsheet-frontmatter-spec.md` — Frontmatter format: metadata, provenance, last-updated, cost indicators
- `cheatsheet-lifecycle.md` — Cheatsheet refresh cadence, staleness checks, deprecation signals
- `cheatsheet-pull-on-demand.md` — Runtime cheatsheet fetching: network fallback, cache policy
- `cheatsheet-crdt-overrides.md` — CRDT-inspired cheatsheet merging: no silent shadowing, reason fields
- `cheatsheet-shortcomings.md` — RUNTIME_LIMITATIONS_NNN.md format for agent-reported gaps
- `agent-startup-skills.md` — Startup skills for agents: project detection, environment setup
- `external-logs.md` — External logs producer: JSONL event format, cheatsheet-telemetry
- `forge-hot-cold-split.md` — Hot path (tmpfs) vs cold path (image RO): /opt/cheatsheets vs /opt/cheatsheets-image
- `forge-paths-ephemeral-vs-persistent.md` — Container paths: ephemeral (lost on stop), persistent (project src), config (writable)
- `forge-shared-cache-via-nix.md` — Nix-managed shared cache: RO to containers, no network pulls at runtime
- `local-inference.md` — Ollama local inference: model selection, performance tuning, VRAM constraints

## utils (continued)

- `curl.md` — curl: HTTP methods, headers, data forms, proxies, redirects, resolve
- `fd.md` — fd-find: find replacement, type filters, --exec, --hidden
- `gh.md` — GitHub CLI: pr/issue/repo/workflow/api, JSON output, scripting patterns
- `jq.md` — jq: JSON filtering, pipes, slurp, joins, transformations
- `ripgrep.md` — ripgrep (rg): patterns, types, multiline, context, JSON output
- `rsync.md` — rsync: -avz, --delete, --exclude, --dry-run, SSH transport
- `ssh.md` — SSH: config, agent forwarding, port forwarding, ProxyJump
- `tree.md` — tree: -L depth, -I exclude patterns, --gitignore, --du
- `tar.md` — tar: compression (gz/bz2/xz/zst), exclude patterns, listing contents
- `shellcheck-shfmt.md` — ShellCheck linting rules and shfmt formatting for shell scripts
- `yq.md` — mikefarah/yq 4.x: YAML/JSON query/update, multi-doc, eval forms

## web (continued)

- `grpc.md` — gRPC: unary/streaming services, gRPC-Web, grpcurl invocation
- `protobuf.md` — Protocol Buffers: proto3 syntax, field numbers, well-known types, codegen
- `openapi.md` — OpenAPI 3.x: spec structure, schemas, security, codegen tools
- `http.md` — HTTP/1.1 and HTTP/2: methods, status codes, headers, idempotency
- `websocket.md` — WebSocket protocol: frames, handshake, subprotocols, common libraries
- `sse.md` — Server-Sent Events: format, reconnection, vs WebSocket
- `cookie-auth-best-practices.md` — Cookie-based auth: secure flags, SameSite, CSRF protection

## welcome

- `readme-discipline.md` — README.md best practices: structure, examples, getting started
- `sample-prompts.md` — Example prompts for agent interaction and project discovery
