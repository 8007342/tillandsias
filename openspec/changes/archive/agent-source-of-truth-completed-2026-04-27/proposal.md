## Why

Coding agents (Claude Code, OpenCode, OpenSpec) running inside the forge container today have no curated reference for what tools the forge ships, what the runtime constraints are (Fedora minimal, immutable image layers, ephemeral mutable overlay), or how to use the tools idiomatically. Agents either guess (wrong defaults, deprecated flags, missing batteries), or they try to install tools at runtime — which violates the ephemeral contract documented in `images/default/Containerfile:18` ("the image IS the toolbox"). When they hit a gap, that knowledge is lost — the next agent rediscovers the same hole.

Specs in `openspec/specs/` similarly drift from the actual tool surface. There is no convention requiring a spec to declare which tool documentation it relied on, so when a tool's behavior changes (e.g., `gh` upgrades from v2.40 to v2.65), specs that depended on the old behavior silently rot.

## What Changes

- **NEW** Top-level `cheatsheets/` directory baked into the forge image at `/opt/cheatsheets/`. Cheatsheets cover: the runtime itself (Fedora-minimal layout, immutable layers, mutable overlay rules), every programming language present in the forge (Python, Rust, Java, Dart, TypeScript, JavaScript, Bash, SQL, JSON, YAML, TOML, HTML, CSS, Markdown), every utility (git, gh, jq, yq, curl, ripgrep, fd, fzf, podman, ssh, rsync, tree, etc.), every build tool (make, cmake, ninja, cargo, npm/yarn/pnpm, pip/pipx/uv/poetry, mvn, gradle, go, flutter), web/API tooling (protobuf, gRPC, OpenAPI, HTTP, WebSocket, SSE), test frameworks (pytest, JUnit, cargo-test, go-test, Selenium, Playwright), and the agent runtimes themselves (Claude Code, OpenCode, OpenSpec).
- **NEW** `cheatsheets/INDEX.md` — single-line-per-entry catalogue of every cheatsheet, grouped by category, queryable by `grep` from any agent.
- **NEW** Container-runtime cheatsheet `cheatsheets/runtime/forge-container.md` documenting: Fedora-minimal 43 base, microdnf vs dnf, the immutable image layers (everything outside the writable home), the mutable overlay boundaries (`/home/forge/src/<project>` workspace, `~/.cache/`, `~/.config/`), best practices (small configs and skills only — no new binaries in user space), and the RUNTIME_LIMITATIONS feedback loop.
- **NEW** RUNTIME_LIMITATIONS feedback channel: agents that hit a missing tool or capability inside the forge SHALL write `<project>/.tillandsias/runtime-limitations/RUNTIME_LIMITATIONS_NNN.md` (sequentially numbered) describing the gap, with structured front-matter the host can scrape on next sync. The host's mirror-sync path already brings `<project>` content back to the host, so the gap reports surface naturally on the next forge stop.
- **MODIFIED** Containerfile bakes the new `cheatsheets/` tree into `/opt/cheatsheets/` at image build time. Forge entrypoint exports `TILLANDSIAS_CHEATSHEETS=/opt/cheatsheets` so agent configs can point at it.
- **MODIFIED** Methodology (`~/src/CLAUDE.md` cross-project conventions + `~/src/tillandsias/CLAUDE.md` project conventions + the OpenSpec proposal/spec/design template) requires that every spec lists at least one cheatsheet it used as source of truth, in a new `## Sources of Truth` section. Specs without sources are valid but flagged as warnings by `openspec validate`.
- **OPTIONAL** Containerfile additions: tools the inventory analysis flagged as missing-but-likely-needed for routine agent work — `shellcheck`, `shfmt`, `yq`, `protobuf-compiler` (`protoc`), `grpcurl`, `bat`, `htop`, `tmux`, `tldr`, `entr`, TypeScript compiler (`typescript` via `npm install -g`), `playwright` browser deps. Each is justified by a corresponding cheatsheet — anything unjustified stays out.

## Capabilities

### New Capabilities
- `agent-cheatsheets`: curated knowledge surface for coding agents — directory layout, INDEX format, runtime cheatsheet, RUNTIME_LIMITATIONS feedback loop, baking into `/opt/cheatsheets/`.

### Modified Capabilities
- `default-image`: bakes `/opt/cheatsheets/` into the forge image; adds the (small) set of utility tools justified by the inventory analysis.
- `spec-traceability`: extends OpenSpec methodology to require `## Sources of Truth` referencing one or more cheatsheets in every new spec.

## Impact

- New top-level directory `cheatsheets/` (~50 markdown files initially) — checked into git, baked into forge image.
- `images/default/Containerfile`: adds `COPY cheatsheets/ /opt/cheatsheets/`, adds `ENV TILLANDSIAS_CHEATSHEETS=/opt/cheatsheets`, adds the small set of tool packages identified by the inventory.
- `images/default/entrypoint*.sh`: ensures `TILLANDSIAS_CHEATSHEETS` is exported to the agent's environment so agents can `cat $TILLANDSIAS_CHEATSHEETS/INDEX.md` without hardcoding the path.
- `~/src/CLAUDE.md` (workspace) and `~/src/tillandsias/CLAUDE.md` (project): new "Sources of Truth" section in workflow conventions; updated OpenSpec rules to require the section in every spec.
- `openspec/changes/<change>/specs/<cap>/spec.md` template via the proposal artifact instructions: `## Sources of Truth` sub-template added.
- `openspec/specs/<cap>/spec.md` for each existing spec: a follow-up sweep adds the section retroactively to existing specs (separate change to keep this one tractable). New specs MUST include the section from day one.
- `mirror-sync.rs`: adds awareness of `.tillandsias/runtime-limitations/` so RUNTIME_LIMITATIONS reports survive forge stop and surface in the host workspace. Implementation may be no-op if mirror sync already brings the entire `<project>` back (likely — the existing path syncs the whole tree).
- Image size: `cheatsheets/` ~few MB of markdown — negligible vs the ~3GB Flutter SDK already in the forge.
- Build time: cheatsheets are a single COPY layer near the end — adds <1s to image rebuild.
- No runtime perf impact, no security boundary changes, no new credentials handled.
