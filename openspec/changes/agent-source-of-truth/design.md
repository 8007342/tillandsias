## Context

The forge container today (`images/default/Containerfile`) ships a heavy battery of tools — full Fedora compiler stack (gcc/clang/cmake/ninja/autotools), Python (+ pipx tools: ruff/black/mypy/pytest/httpie/uv/poetry), Node + npm + yarn + pnpm, Java 21 + Maven + Gradle 8.10, Go, Rust, Flutter 3.24.5 (web + desktop precached), git/gh/curl/wget/jq/ripgrep/fd/fzf, sqlite + postgresql clients, baked agents at `/opt/agents/{claude,opencode,openspec}` — but agents running inside the forge have no curated reference for any of it. Each agent improvises: re-deriving CLI flags from `--help`, missing battery-included options like `pipx run`, occasionally trying to install something at runtime (which violates the Fedora-minimal ephemeral contract since `/usr` is image-state, not user-state).

Specs in `openspec/specs/` are similarly opaque about which tool documentation they relied on. When `gh` ships a breaking flag rename, no spec mentions `gh` — so we discover the rot by failing CI months later. The methodology requires `@trace spec:<name>` annotations *from code to spec*, but offers no equivalent in the other direction (spec → tool documentation).

This change adds a curated `cheatsheets/` directory that lives both in the repo (so it's reviewable, version-controlled, and editable) and gets baked into the forge image at `/opt/cheatsheets/` (so agents inside the container can read it without round-tripping to the host). It also extends the OpenSpec methodology to require every spec to declare the cheatsheets it used as source of truth.

## Goals / Non-Goals

**Goals:**
- A single discoverable directory of cheatsheets, indexed in `cheatsheets/INDEX.md`, organized by category (`runtime/`, `languages/`, `utils/`, `build/`, `web/`, `test/`, `agents/`).
- Every cheatsheet ≤ 200 lines, scannable in <30 seconds. Each ends with a "Common pitfalls" or "Notes" section so agents avoid known traps.
- Forge image bakes the directory at `/opt/cheatsheets/` and exports `TILLANDSIAS_CHEATSHEETS` so agents discover it via env var rather than hardcoded path.
- A `RUNTIME_LIMITATIONS_NNN.md` convention so agents that hit a missing tool report it back to the host, where the human triages whether to add it.
- OpenSpec methodology requires `## Sources of Truth` listing one or more cheatsheets in every new spec. `openspec validate` warns (not errors) if the section is missing — non-blocking so we can adopt incrementally.
- Initial cheatsheet writing happens in parallel waves via sub-agents — the proposal captures the inventory and the structure; the actual writing is delegated.

**Non-Goals:**
- Retroactively adding `## Sources of Truth` to every existing spec. That is a separate sweep change once this one is archived.
- Adding heavy tools the inventory says we lack (Android SDK, Xcode, Visual Studio components). Out of scope; the forge stays Linux-desktop-friendly only.
- Dynamic cheatsheet generation from `--help` output. Considered and rejected — `--help` is verbose, version-coupled, and rots silently. Curated markdown is more durable.
- A web UI to browse cheatsheets. Agents read markdown directly via `cat` / `rg`; humans use the GitHub rendering of the same files.

## Decisions

### Decision 1: Top-level `cheatsheets/` directory, NOT under `docs/`

**Choice**: Place the new directory at the project root (`cheatsheets/`), separate from the existing `docs/cheatsheets/`.

**Why**: The existing `docs/cheatsheets/` are project-specific operational guides (tray state machine, secrets management, token rotation) — they document *how Tillandsias works*. The new `cheatsheets/` are general-purpose tool references baked into the forge image — they document *the tools the forge ships*. The distinction matters because `docs/cheatsheets/` belongs to the host (read by maintainers); `cheatsheets/` belongs to the forge (read by agents inside the container).

**Alternative rejected**: Nest under `docs/cheatsheets/agent/`. Buries the agent-facing content one level deeper than necessary, and the `docs/` parent implies "documentation about Tillandsias" which the agent cheatsheets aren't.

### Decision 2: Categorization by use, not by tool family

**Choice**: Subdirectories are `runtime/`, `languages/`, `utils/`, `build/`, `web/`, `test/`, `agents/`. Not `python/`, `rust/`, `java/` etc.

**Why**: An agent looking for "how do I run a unit test in Rust" wants `test/cargo-test.md`, not `languages/rust.md` (which would mix syntax, build, and test). The use-based split keeps each cheatsheet narrowly scoped (≤ 200 lines) and lets agents jump straight to the verb they need.

**Cross-references**: Each `languages/<lang>.md` includes "See also" links to its build, test, and idiomatic-formatter cheatsheets. INDEX.md groups entries by the same categories for human discoverability.

### Decision 3: INDEX.md is grep-friendly, one line per cheatsheet

**Choice**: `cheatsheets/INDEX.md` format:

```
## languages
- python.md             — Python 3.13 syntax + idioms (PEP 8, type hints, dataclasses, match)
- rust.md               — Rust edition 2024 syntax + ownership patterns + iter idioms
- java.md               — Java 21 syntax + records + sealed classes + virtual threads
...

## utils
- jq.md                 — jq 1.7 — filters, pipes, --slurp, joins, lookups
- ripgrep.md            — ripgrep 14 — patterns, --type, --multiline, replacements
...
```

Each line ≤ 100 chars so an agent can `cat $TILLANDSIAS_CHEATSHEETS/INDEX.md | rg <topic>` and get exactly one match per relevant entry.

**Why**: Agents are generally efficient at `grep` and `cat`; an HTML index would force a browser spawn or a markdown-to-text conversion. Plain text wins.

### Decision 4: Cheatsheet template is fixed

**Choice**: Every cheatsheet uses this template:

```markdown
# <Tool/Language Name>

@trace spec:agent-cheatsheets

**Version baseline**: <version pinned in the forge>
**Use when**: <one-line elevator pitch — the situation this cheatsheet covers>

## Quick reference
[scannable table or short bullet list of the most-used commands/syntax]

## Common patterns
[3–5 idiomatic snippets agents will write all the time]

## Common pitfalls
[3–10 traps — wrong defaults, deprecated flags, gotchas]

## See also
- <category>/<other-cheatsheet>.md
- <category>/<other-cheatsheet>.md
```

**Why**: A fixed template means an agent (or sub-agent writing them in waves) knows exactly what sections to fill. The "Common pitfalls" section is mandatory because it's the highest-leverage piece — flagging known traps prevents the next agent from making the same mistake.

### Decision 5: Bake into image, do NOT bind-mount

**Choice**: `COPY cheatsheets/ /opt/cheatsheets/` in the Containerfile, baked at image build time. No bind-mount from the host at runtime.

**Why**: The forge container is intentionally credential-free and offline (`spec:forge-offline`). A bind-mount from host to forge would give the forge a live read into the host filesystem, breaking the isolation. Baking means each forge image version pins a specific cheatsheet snapshot — when we update cheatsheets, we rebuild the image (cheap; cheatsheets are a final tiny COPY layer). Cheatsheets on disk inside the forge are read-only: if an agent thinks one is wrong, it writes a `RUNTIME_LIMITATIONS_NNN.md` rather than editing the cheatsheet directly.

**Alternative rejected**: Bind-mount `cheatsheets/` from host. Breaks `spec:forge-offline` and `spec:enclave-network`. Also breaks reproducibility — two forges of the same image version would see different cheatsheets if the host edited them mid-session.

### Decision 6: RUNTIME_LIMITATIONS_NNN.md format and location

**Choice**: When an agent inside the forge encounters a missing tool, it writes:

```markdown
---
report_id: NNN
tool: <name-of-missing-tool>
attempted: <what the agent tried to do>
suggested_install: <what it would have run on a non-restricted host>
discovered_at: <ISO 8601>
---

# Runtime limitation NNN — <one-line headline>

<3-10 lines explaining the gap and what the agent did instead>
```

Path: `<project>/.tillandsias/runtime-limitations/RUNTIME_LIMITATIONS_NNN.md`

NNN is a sequential number — the agent globs the directory, finds the highest existing NNN, increments by 1.

**Why**: Front-matter makes the reports machine-parseable for batch triage. The path lives inside `<project>` so the existing mirror-sync (`src-tauri/src/mirror_sync.rs`) brings them back to the host on forge stop. No new I/O channel needed.

**Triage path** (out of scope for this change): a host-side script `scripts/triage-runtime-limitations.sh` that lists all reports across all projects, ordered by frequency. Future work.

### Decision 7: Methodology change is a CLAUDE.md edit, not a code change

**Choice**: The methodology update lives in two CLAUDE.md files and the OpenSpec proposal/design/spec instruction templates. No Rust/code change for the methodology side.

**Why**: CLAUDE.md is the canonical methodology document Claude reads at session start. OpenSpec's instruction templates are what `openspec instructions <artifact>` returns, which is what shapes new spec writing. Changing both is sufficient — no need for a `lint-spec-has-sources.sh` enforcement script in this change (could come later, but soft adoption first per `feedback_convergence_philosophy: warnings not errors`).

**Note on OpenSpec instruction template**: The spec instruction template that `openspec instructions specs` returns lives in the OpenSpec CLI tool, outside this repository. Task 2.3 requires propagating a sentence to that template indicating `## Sources of Truth` is expected in new specs. This is an out-of-band change: the OpenSpec project owner must update their template instructions after this change is archived. The CLAUDE.md files in tillandsias and ~/src/ already document the requirement, so local adoption can begin immediately.

### Decision 8: Initial cheatsheet writing is delegated to sub-agents in waves

**Choice**: This change provides the directory structure, the template, the INDEX skeleton, the runtime cheatsheet, and the agent cheatsheets (claude, opencode, openspec). It also seeds 3–4 high-priority cheatsheets (python, rust, bash, jq) as exemplars of the template. Everything else is written by sub-agents spawned in parallel waves AFTER this change's structure is in place.

**Why**: 50+ cheatsheets is too much for one synchronous pass. The structure decisions belong in this change; the content production is straightforward fan-out work that doesn't require a human review per cheatsheet.

**Wave plan** (executed inside `tasks.md`):
- Wave A — high-priority languages (python, rust, java, ts, js, bash, dart) — 7 sub-agents in parallel
- Wave B — remaining languages + data formats (sql, json, yaml, toml, html, css, markdown, xml) — 8 sub-agents in parallel
- Wave C — utils (git, gh, jq, yq, curl, ripgrep, fd, fzf, ssh, rsync, tree, podman) — 12 sub-agents in parallel
- Wave D — build tools (cargo, npm, pnpm, yarn, pip, pipx, uv, poetry, mvn, gradle, go, flutter, make, cmake, ninja) — 15 sub-agents in parallel
- Wave E — web/api/test (protobuf, grpc, openapi, http, websocket, sse, pytest, junit, cargo-test, go-test, selenium, playwright) — 12 sub-agents in parallel

After each wave: build forge image, run smoke test, advance to next wave. Failed cheatsheets are noted in tasks.md but don't block subsequent waves.

## Risks / Trade-offs

- **Risk**: 50+ cheatsheets is a lot to write and keep current. Each new tool version risks rotting the cheatsheet. → **Mitigation**: every cheatsheet pins the version it documents (`Version baseline: ...` line). When the forge upgrades a tool, a CI check (future work) flags any cheatsheet whose pinned version diverges from `images/default/Containerfile`.
- **Risk**: Sub-agents writing cheatsheets in parallel may produce inconsistent quality. → **Mitigation**: the template forces uniform structure. Each agent gets the seed cheatsheets (python, rust, bash, jq) as quality reference. Wave-end build + smoke test catches gross mistakes (e.g., bad markdown breaking the INDEX).
- **Risk**: `## Sources of Truth` requirement adds friction to spec writing. → **Mitigation**: warning, not error. Specs without it still validate. Existing specs get a separate retroactive sweep change.
- **Risk**: Agents inside the forge might ignore `/opt/cheatsheets/` and continue to improvise. → **Mitigation**: the forge entrypoint's welcome script (`forge-welcome.sh`) prints the cheatsheet path on first agent launch. The agent's system prompt (via opencode config or claude config) can be updated in a follow-up change to instruct "consult `/opt/cheatsheets/INDEX.md` before guessing".
- **Trade-off**: Bake-into-image means cheatsheet edits require image rebuild + reattach. Slower iteration than bind-mount. → **Accepted**: reproducibility and `spec:forge-offline` win. Cheatsheets shouldn't change often after initial production.
- **Risk**: RUNTIME_LIMITATIONS reports could be voluminous if an agent gets confused. → **Mitigation**: the agent must include `attempted:` and `suggested_install:` fields, which force it to think before writing. A flood of low-quality reports surfaces a different problem (agent prompt quality) we'd want to know about anyway.

## Sources of Truth

This change introduces the convention; its own design draws on:
- `runtime/forge-container.md` (this change creates it) — the runtime contract every cheatsheet operates inside.
- `agents/openspec.md` (this change creates it) — the OpenSpec methodology this change extends.
- Existing `images/default/Containerfile` is the inventory ground-truth.
