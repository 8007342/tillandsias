## 1. Directory + index skeleton

- [ ] 1.1 Create `cheatsheets/` at repo root with subdirectories `runtime/`, `languages/`, `utils/`, `build/`, `web/`, `test/`, `agents/`. Add a `.gitkeep` to each so they survive an empty initial commit.
- [ ] 1.2 Create `cheatsheets/INDEX.md` skeleton — header explaining the format, then one `## <category>` section per subdirectory, each section initially empty (filled as cheatsheets land in waves).
- [ ] 1.3 Create `cheatsheets/TEMPLATE.md` — the canonical cheatsheet template defined in `design.md` decision 4. Sub-agents in subsequent waves copy this for each new cheatsheet.

## 2. Methodology updates (CLAUDE.md + OpenSpec template)

- [ ] 2.1 Add a `## Sources of Truth` section to `~/src/CLAUDE.md` (cross-project workspace conventions): describes the convention, points at `cheatsheets/`, lists the format `- <category>/<filename>.md  — <reason>`, notes the warn-not-error policy.
- [ ] 2.2 Mirror the same section in `~/src/tillandsias/CLAUDE.md` (project-local conventions), pinning paths to this repo.
- [ ] 2.3 Update the OpenSpec specs template guidance — add a sentence to the spec instruction returned by `openspec instructions specs` indicating the `## Sources of Truth` section is expected. (If the template lives in a config file this change can edit, do so; otherwise leave a note in `design.md` documenting that the template lives outside this repo and the OpenSpec project owner must propagate the change.)
- [ ] 2.4 Update the change's own template usage: this change's `proposal.md` and `specs/*/spec.md` already cite cheatsheets where they exist (this change creates them), so they self-validate.

## 3. Container-runtime cheatsheet (the foundational one)

- [ ] 3.1 Write `cheatsheets/runtime/forge-container.md` covering: Fedora minimal 43 base, microdnf vs dnf (forge ships microdnf only), the immutable image layers (everything outside `$HOME` is image-state — read-only at runtime), the writable mutable overlay boundaries (`$HOME/src/<project>` workspace, `$HOME/.cache/`, `$HOME/.config/`), best practices (small configs and skills only, no new binaries in user space), how to consult `/opt/cheatsheets/INDEX.md`, and the RUNTIME_LIMITATIONS feedback loop.
- [ ] 3.2 Write `cheatsheets/runtime/runtime-limitations.md` covering the RUNTIME_LIMITATIONS_NNN.md format: front-matter fields, location convention, sequential numbering, how the host triages reports.
- [ ] 3.3 Write `cheatsheets/runtime/networking.md` covering the enclave network: forge has no external network; egress goes through the proxy; git via the enclave-internal mirror; inference via local ollama at `inference:11434`. Anti-patterns: `curl https://...` from the forge (will fail unless going through proxy + cert trust), `pip install` from PyPI (use proxy or accept failure).

## 4. Agent runtime cheatsheets

- [ ] 4.1 Write `cheatsheets/agents/claude-code.md` — Claude Code CLI: launching, model flags, hooks, skills, MCP. Pinned version from forge image.
- [ ] 4.2 Write `cheatsheets/agents/opencode.md` — OpenCode CLI + web mode: serve port, session DB, theme config, parallel sessions on same forge.
- [ ] 4.3 Write `cheatsheets/agents/openspec.md` — OpenSpec workflow (`openspec new change`, `openspec instructions`, `openspec validate`, `openspec status`); the artifact lifecycle proposal → design → specs → tasks → archive.

## 5. Wave A — high-priority languages (parallel sub-agents)

Spawn 7 sub-agents in parallel, one per language. Each writes one cheatsheet using the `TEMPLATE.md` format, pinning the version from the forge inventory. Total: 7 files.

- [ ] 5.1 `cheatsheets/languages/python.md` — Python 3.13 syntax, type hints, dataclasses, match statement, asyncio basics, common stdlib (pathlib, json, subprocess), virtual env conventions in forge (pipx vs pip vs uv).
- [ ] 5.2 `cheatsheets/languages/rust.md` — Rust edition 2024, ownership, borrowing, lifetimes (one example each), Result/Option idioms, iter chains, common derives, async with tokio basics.
- [ ] 5.3 `cheatsheets/languages/java.md` — Java 21 LTS, records, sealed classes, pattern matching, virtual threads, common Stream patterns, Maven coords format.
- [ ] 5.4 `cheatsheets/languages/typescript.md` — TS 5.x, type inference, generics, utility types (Pick/Omit/Partial), discriminated unions, async patterns, tsconfig essentials.
- [ ] 5.5 `cheatsheets/languages/javascript.md` — Modern JS: const/let, destructuring, spread, async/await, optional chaining, nullish coalescing, ESM vs CJS, common Array methods.
- [ ] 5.6 `cheatsheets/languages/bash.md` — Strict mode (`set -euo pipefail`), parameter expansion, arrays, `[[ ]]` vs `[ ]`, redirection, here-docs, signal traps, common pitfalls (word splitting, quoting).
- [ ] 5.7 `cheatsheets/languages/dart.md` — Dart 3 sound null safety, classes, mixins, async/await, Stream basics, Flutter-relevant idioms.

## 6. Wave B — remaining languages + data formats (parallel sub-agents)

8 sub-agents in parallel.

- [ ] 6.1 `cheatsheets/languages/sql.md` — Standard SQL: SELECT, JOIN types, GROUP BY + HAVING, window functions, CTEs, transactions. Postgres + SQLite divergences (the forge ships clients for both).
- [ ] 6.2 `cheatsheets/languages/json.md` — JSON syntax, common pitfalls (no comments, no trailing commas, only double quotes), JSON Lines, JSON Pointer.
- [ ] 6.3 `cheatsheets/languages/yaml.md` — YAML 1.2 basics, indent semantics, anchors/aliases, the Norway problem, multi-line strings (`|` vs `>`), mapping vs sequence pitfalls.
- [ ] 6.4 `cheatsheets/languages/toml.md` — TOML 1.0 basics, tables, arrays-of-tables, dotted keys, vs YAML/JSON tradeoffs.
- [ ] 6.5 `cheatsheets/languages/html.md` — HTML5 semantic tags, ARIA basics, common pitfalls (block-vs-inline, nested forms).
- [ ] 6.6 `cheatsheets/languages/css.md` — Modern CSS: flexbox, grid, custom properties, container queries, common pitfalls (specificity, stacking contexts).
- [ ] 6.7 `cheatsheets/languages/markdown.md` — CommonMark + GFM, code fences, tables, footnotes, link reference style, GitHub-specific extensions (task lists, mentions).
- [ ] 6.8 `cheatsheets/languages/xml.md` — XML basics, namespaces, XPath fundamentals, when to use vs JSON/YAML.

## 7. Wave C — utils (parallel sub-agents)

12 sub-agents in parallel.

- [ ] 7.1 `cheatsheets/utils/git.md` — git 2.x: commit/branch/log/diff/rebase, common workflows, recovery from common mistakes, hooks basics.
- [ ] 7.2 `cheatsheets/utils/gh.md` — GitHub CLI: pr / issue / repo / workflow / api commands, JSON output mode, scripting patterns.
- [ ] 7.3 `cheatsheets/utils/jq.md` — jq 1.7: filters, pipes, --slurp, joins, lookups, common transformations.
- [ ] 7.4 `cheatsheets/utils/yq.md` — mikefarah/yq 4.x (added by this change): query/update YAML, multi-doc files, the `eval` form vs `eval-all`.
- [ ] 7.5 `cheatsheets/utils/curl.md` — curl: HTTP methods, headers, --data forms, --form, follow redirects, --resolve, proxy env vars (relevant in forge).
- [ ] 7.6 `cheatsheets/utils/ripgrep.md` — rg 14: patterns, --type, --multiline, -A/-B/-C, replacements, --json output.
- [ ] 7.7 `cheatsheets/utils/fd.md` — fd-find: replacement for `find`, type filters, --exec, --hidden flag.
- [ ] 7.8 `cheatsheets/utils/fzf.md` — fzf: --bind, --preview, common shell integrations, multi-select.
- [ ] 7.9 `cheatsheets/utils/ssh.md` — ssh: client config, agent forwarding, port forwarding, ProxyJump, known_hosts.
- [ ] 7.10 `cheatsheets/utils/rsync.md` — rsync: -avz, --delete, --exclude, --dry-run, ssh transport.
- [ ] 7.11 `cheatsheets/utils/tree.md` — tree: -L depth, -I exclude, --gitignore, --du.
- [ ] 7.12 `cheatsheets/utils/shellcheck-shfmt.md` — shellcheck rules + auto-fix, shfmt formatting flags. (Both added by this change.)

## 8. Wave D — build tools (parallel sub-agents)

15 sub-agents in parallel.

- [ ] 8.1 `cheatsheets/build/cargo.md` — Cargo: build/test/run/check/clippy/fmt/doc, workspaces, features, target dirs.
- [ ] 8.2 `cheatsheets/build/npm.md` — npm: install/run/publish, package.json scripts, workspaces.
- [ ] 8.3 `cheatsheets/build/pnpm.md` — pnpm: install/run/-w (workspaces), --filter, why-pnpm-vs-npm.
- [ ] 8.4 `cheatsheets/build/yarn.md` — yarn classic vs berry, install/run/workspaces.
- [ ] 8.5 `cheatsheets/build/pip.md` — pip: install, requirements.txt, constraints.txt, editable installs, --no-deps.
- [ ] 8.6 `cheatsheets/build/pipx.md` — pipx: install/run/inject, --python, where binaries land.
- [ ] 8.7 `cheatsheets/build/uv.md` — uv: drop-in pip replacement, lockfile, project mode.
- [ ] 8.8 `cheatsheets/build/poetry.md` — poetry: init/install/add/build/publish, vs pip+venv.
- [ ] 8.9 `cheatsheets/build/maven.md` — Maven: lifecycle phases, common plugins, dependency management, profiles.
- [ ] 8.10 `cheatsheets/build/gradle.md` — Gradle 8.x: tasks, dependency configurations, wrapper, Kotlin DSL basics.
- [ ] 8.11 `cheatsheets/build/go.md` — Go modules: go mod init/tidy/get, build/test/run/vet, GOPATH-vs-module-mode.
- [ ] 8.12 `cheatsheets/build/flutter.md` — Flutter 3.24: pub get, run --device-id, build (web/desktop), no-android/ios in this forge.
- [ ] 8.13 `cheatsheets/build/make.md` — GNU make: rules, automatic variables, .PHONY, common pitfalls (tabs, recursive expansion).
- [ ] 8.14 `cheatsheets/build/cmake.md` — CMake 3.x: project, target_*, find_package, generator expressions.
- [ ] 8.15 `cheatsheets/build/ninja.md` — Ninja: when used, build.ninja format basics, vs make.

## 9. Wave E — web/api/test (parallel sub-agents)

12 sub-agents in parallel.

- [ ] 9.1 `cheatsheets/web/protobuf.md` — proto3 syntax, common types, compilation with protoc, language plugins.
- [ ] 9.2 `cheatsheets/web/grpc.md` — gRPC concepts, unary/streaming, gRPC-web, grpcurl invocation.
- [ ] 9.3 `cheatsheets/web/openapi.md` — OpenAPI 3.x structure, common refactoring patterns, codegen tools.
- [ ] 9.4 `cheatsheets/web/http.md` — HTTP/1.1 + HTTP/2 basics, methods, status codes, common headers, idempotency.
- [ ] 9.5 `cheatsheets/web/websocket.md` — WS protocol, framing, common libraries by language.
- [ ] 9.6 `cheatsheets/web/sse.md` — Server-sent events, format, reconnection, vs WS.
- [ ] 9.7 `cheatsheets/test/pytest.md` — pytest: discovery, fixtures, parametrize, conftest, plugins.
- [ ] 9.8 `cheatsheets/test/junit.md` — JUnit 5: @Test, @BeforeEach, parameterized, assertions.
- [ ] 9.9 `cheatsheets/test/cargo-test.md` — `cargo test`: discovery, --workspace, integration tests, doctests.
- [ ] 9.10 `cheatsheets/test/go-test.md` — `go test`: -run, table-driven, t.Helper, subtests, benchmarks.
- [ ] 9.11 `cheatsheets/test/selenium.md` — Selenium: WebDriver basics, when to use, browser deps inside forge.
- [ ] 9.12 `cheatsheets/test/playwright.md` — Playwright: browser auto-install, fixtures, when to choose vs Selenium.

## 10. Containerfile updates

- [ ] 10.1 Add `COPY cheatsheets/ /opt/cheatsheets/` and `ENV TILLANDSIAS_CHEATSHEETS=/opt/cheatsheets` to `images/default/Containerfile`. Place the COPY near the end (after `/opt/agents/`, before locale files) so the layer is small and rebuild-cheap.
- [ ] 10.2 Add the optional tools in one new `microdnf install -y` layer: `ShellCheck shfmt protobuf-compiler protobuf-devel`. (`yq` and `grpcurl` are not in Fedora's repos — fetch via curl in the same layer, mirror the Gradle pattern.)
- [ ] 10.3 Update `forge-welcome.sh` to print the cheatsheet hint line.
- [ ] 10.4 Update `flake.nix` to mirror the same additions for parity (so Nix-backend builds also have the tools — even though the default backend is Fedora).

## 11. Build, test, verify

- [ ] 11.1 Build forge image: `scripts/build-image.sh forge --force`. Capture build time.
- [ ] 11.2 Smoke test inside the new image: `podman run --rm tillandsias-forge:v<version> sh -c 'ls /opt/cheatsheets/INDEX.md && echo $TILLANDSIAS_CHEATSHEETS && shellcheck --version && yq --version && protoc --version && grpcurl -version'`.
- [ ] 11.3 If smoke test passes, install: `./build.sh --install` then launch tray, attach to a project, exec into the forge, verify cheatsheets are visible and `cat $TILLANDSIAS_CHEATSHEETS/INDEX.md` returns the index.
- [ ] 11.4 Run the test suite: `cargo test --workspace --lib`, `cargo test -p tillandsias --bin tillandsias`. Should be a no-op since this change has no Rust code, but confirms nothing accidentally broke.

## 12. Cheatsheet writing infrastructure

- [ ] 12.1 Verify INDEX.md has every cheatsheet from waves A–E, in the right category section, with one-line descriptions ≤ 100 chars.
- [ ] 12.2 Run a final pass adding cross-references in each cheatsheet's `## See also` section so the graph is connected.

## 13. Trace + version

- [ ] 13.1 Each new cheatsheet carries `@trace spec:agent-cheatsheets` near the top per the template.
- [ ] 13.2 No version bump now — happens at archive per CLAUDE.md.
