# Cheatsheets Index

@trace spec:agent-cheatsheets

Curated reference for tools, languages, and runtimes shipped with the Tillandsias forge. Optimised for `cat | rg`: one line per cheatsheet, ≤ 100 chars, `<filename> — <one-line description>`.

**Discovery**: agents inside the forge find cheatsheets at `$TILLANDSIAS_CHEATSHEETS/INDEX.md` (resolves to `/opt/cheatsheets/INDEX.md`). Humans read them on GitHub.

**Authoring**: copy `cheatsheets/TEMPLATE.md` into the right category subdirectory, fill the sections, then add a one-liner to the matching `## <category>` heading below. Pin a `Version baseline:` line.

## runtime

- forge-container.md          — [DRAFT] Fedora minimal 43 forge layout, immutable layers, mutable overlay rules
- runtime-limitations.md      — [DRAFT] RUNTIME_LIMITATIONS_NNN.md format + how to report missing tools
- networking.md               — [DRAFT] enclave network, proxy egress, no direct internet, mirror git, ollama inference
- cheatsheet-architecture-v2.md   — fine-grained per-use-case structure, frontmatter, MCP query interface
- cheatsheet-frontmatter-spec.md  — YAML frontmatter schema (tags / sources / authority / status)
- cheatsheet-shortcomings.md      — gap inventory after the v2 sweep (10 prioritized items)

## algorithms

- binary-search.md            — O(log n) on sorted arrays; iterative + lower_bound + predicate-based; pitfalls

## patterns

- gof-observer.md             — Observer pattern (GoF behavioural); push vs pull; pitfalls; when not to use

## architecture

- event-driven-basics.md      — Fowler's four flavors of EDA (Notification / Carried-State / Sourcing / CQRS)
- reactive-streams-spec.md    — Publisher/Subscriber/Subscription/Processor + backpressure; library landscape

## security

- owasp-top-10-2021.md        — current Top 10 risk-ranked checklist; per-item one-line fix; concrete patterns

## data

- postgresql-indexing-basics.md  — B-tree / GIN / GiST / BRIN; composite ordering; partial / expression / covering / CONCURRENT

## languages

- python.md                   — Python 3.13 syntax + idioms (PEP 8, type hints, dataclasses, match)
- rust.md                     — Rust edition 2024 syntax + ownership patterns + iter idioms
- java.md                     — Java 21 syntax + records + sealed classes + virtual threads
- typescript.md               — TS 5.x type inference, generics, utility types, async patterns
- javascript.md               — Modern JS: const/let, destructuring, async/await, ESM vs CJS
- bash.md                     — Strict mode, parameter expansion, arrays, common quoting traps
- dart.md                     — Dart 3 sound null safety, classes, mixins, async
- sql.md                      — Standard SQL with Postgres + SQLite divergences
- json.md                     — JSON syntax + JSON Lines + JSON Pointer + common pitfalls
- yaml.md                     — YAML 1.2 indent semantics, anchors, the Norway problem
- toml.md                     — TOML 1.0 tables + arrays-of-tables, vs YAML/JSON
- xml.md                      — XML basics + namespaces + XPath fundamentals
- html.md                     — HTML5 semantic tags + ARIA basics
- css.md                      — Modern CSS: flexbox, grid, custom properties, container queries
- markdown.md                 — [DRAFT] CommonMark + GFM (tables, footnotes, code fences, task lists)
- java/rxjava-event-driven.md — RxJava 3.x async/event-driven; Flowable vs Observable; debounce/combine/retry

## utils

- git.md                      — git 2.x: commit/branch/log/diff/rebase + recovery patterns
- gh.md                       — GitHub CLI: pr/issue/repo/workflow/api + JSON scripting
- jq.md                       — jq 1.7: filters, pipes, --slurp, joins, lookups
- yq.md                       — mikefarah/yq 4.x: query/update YAML, multi-doc files
- curl.md                     — curl: HTTP methods, --data, --form, --resolve, proxy env
- ripgrep.md                  — rg 14: patterns, --type, --multiline, --json output
- fd.md                       — fd-find: find replacement, type filters, --hidden
- fzf.md                      — fzf: --bind, --preview, multi-select, shell integrations
- ssh.md                      — ssh client config, agent forwarding, ProxyJump
- rsync.md                    — rsync: -avz, --delete, --exclude, --dry-run, ssh transport
- tree.md                     — tree: -L, -I, --gitignore, --du
- shellcheck-shfmt.md         — ShellCheck rules + auto-fix + shfmt formatting flags

## build

- cargo.md                    — Cargo: build/test/run/check/clippy/fmt/doc + workspaces
- npm.md                      — npm: install/run/publish + package.json scripts + workspaces
- pnpm.md                     — pnpm: install/run/-w + --filter + why-vs-npm
- yarn.md                     — yarn classic vs berry: install/run/workspaces
- pip.md                      — pip: install + requirements.txt + editable + --no-deps
- pipx.md                     — pipx: install/run/inject + where binaries land
- uv.md                       — uv: drop-in pip replacement + lockfile + project mode
- poetry.md                   — poetry: init/install/add/build + vs pip+venv
- maven.md                    — Maven: lifecycle phases + plugins + profiles
- gradle.md                   — Gradle 8.x: tasks + configurations + wrapper + Kotlin DSL
- go.md                       — Go modules: mod init/tidy/get + build/test/run/vet
- flutter.md                  — Flutter 3.24: pub get + run + build (web/desktop only here)
- make.md                     — GNU make: rules + automatic vars + .PHONY + tab pitfalls
- cmake.md                    — CMake 3.x: project + target_* + find_package + generator expr
- ninja.md                    — [DRAFT] Ninja: build.ninja format + when chosen vs make
- nix-flake-basics.md         — minimal flake; devShell; multi-system via flake-utils; direnv integration

## web

- protobuf.md                 — proto3 syntax + types + protoc + language plugins
- grpc.md                     — gRPC concepts + unary/streaming + grpcurl invocation
- openapi.md                  — OpenAPI 3.x structure + refactoring + codegen
- http.md                     — HTTP/1.1 + HTTP/2 methods + status codes + headers + idempotency
- websocket.md                — WS protocol + framing + libraries by language
- sse.md                      — Server-sent events: format + reconnection + vs WS

## test

- pytest.md                   — pytest: discovery + fixtures + parametrize + conftest + plugins
- junit.md                    — JUnit 5: @Test + @BeforeEach + parameterized + assertions
- cargo-test.md               — cargo test: discovery + --workspace + integration + doctests
- go-test.md                  — go test: -run + table-driven + t.Helper + benchmarks
- selenium.md                 — Selenium WebDriver basics + browser deps inside forge
- playwright.md               — Playwright: browser auto-install + fixtures + vs Selenium

## agents

- claude-code.md              — Claude Code CLI: launching + model flags + hooks + skills + MCP
- opencode.md                 — OpenCode CLI + web mode: serve port + session DB + theme
- openspec.md                 — OpenSpec: proposal → design → specs → tasks → archive workflow

## privacy

(empty — to be populated; see `cheatsheet-shortcomings.md` priority list)

