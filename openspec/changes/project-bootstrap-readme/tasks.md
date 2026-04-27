# Tasks — project-bootstrap-readme

Phased so each task is verifiable in a single PR. Order is dependency-driven (cheatsheets first, then summarizers, then dispatcher/validator, then skills, then entrypoint shim, then telemetry, then per-project migration). Items deferred to follow-up changes (auto-promotion, telemetry consumption, allowlist auto-merge, cross-project sharing) are explicitly OUT of scope.

## 1. Cheatsheets (the agent-facing reference layer)

- [x] 1.1 Author `cheatsheets/welcome/sample-prompts.md` with at minimum 9 curated sample prompts spanning at least 4 domains (game, business tool, education, creative). `tier: bundled`. Provenance citing one authoritative source on prompting patterns.
- [x] 1.2 Author `cheatsheets/welcome/readme-discipline.md` documenting the FOR HUMANS / FOR ROBOTS structure, the auto-regen warning, the seven mandatory FOR ROBOTS subsections, the requires_cheatsheets YAML block schema, and the readme.traces format. `tier: bundled`. Provenance.
- [x] 1.3 Author `cheatsheets/runtime/agent-startup-skills.md` documenting the four skills (`/startup`, `/bootstrap-readme-and-project`, `/bootstrap-readme`, `/status`), their routing matrix, the empty-project detection heuristic, and how the OpenCode entrypoint shim invokes `/startup`. `tier: bundled`. Provenance.
- [x] 1.4 Update `cheatsheets/INDEX.md` to add a `## welcome` section and the three new lines under runtime.

## 2. Per-language summarizer scripts

- [x] 2.1 Implement `scripts/summarize-cargo.sh` per the project-summarizers interface (argv contract, exit-code semantics, markdown stdout under H3s). Test against `Cargo.toml` (Tillandsias workspace).
- [x] 2.2 Implement `scripts/summarize-nix.sh` (parses `flake.nix` outputs + `flake.lock` input pins).
- [x] 2.3 Implement `scripts/summarize-package-json.sh` (parses `dependencies` + `devDependencies`).
- [x] 2.4 Implement `scripts/summarize-pubspec.sh` (Flutter SDK pin, dart deps).
- [x] 2.5 Implement `scripts/summarize-go-mod.sh` (module path, Go version, top-level requires).
- [x] 2.6 Implement `scripts/summarize-pyproject.sh` (build-backend, deps, optional `[tool.poetry]`).
- [x] 2.7 Each summarizer SHALL exit 2 (not 1) when its target manifest is absent — distinguishes "skip" from "error".

## 3. README dispatcher + validator

- [x] 3.1 Implement `scripts/regenerate-readme.sh` per the project-summarizers spec: walk to project root, invoke each summarizer, render FOR HUMANS + FOR ROBOTS, atomic write to README.md.
- [x] 3.2 Render the FOR HUMANS section: line-1 auto-regen warning, timestamp (coarse to minutes + timezone), ASCII art banner from a curated cache, install snippet, whimsical 3-line description.
- [x] 3.3 Render the FOR ROBOTS section: concatenation of summarizer outputs under `## Tech Stack` and `## Build/Runtime Dependencies`; preserve agent-curated `## Security`, `## Architecture`, `## Privacy` from the previous README; append `## Recent Changes`, `## OpenSpec — Open Items`, requires_cheatsheets YAML.
- [x] 3.4 Implement `scripts/check-readme-discipline.sh` per the project-bootstrap-readme spec: validate header warning string, two H1s, seven FOR ROBOTS H2s, requires_cheatsheets YAML well-formed, timestamp ≤ 7 days. ERROR on missing structure; WARN on stale timestamp.

## 4. The four skill files

- [x] 4.1 Author `images/default/config-overlay/opencode/agent/startup.md` — entrypoint, reads project state, branches via `git ls-files | wc -l` heuristic + README presence + validator exit code.
- [x] 4.2 Author `images/default/config-overlay/opencode/agent/bootstrap-readme-and-project.md` — empty-project welcome flow; reads `cheatsheets/welcome/sample-prompts.md`; renders banner + 3 randomly-picked prompts + forge capability summary + open prompt.
- [x] 4.3 Author `images/default/config-overlay/opencode/agent/bootstrap-readme.md` — invokes `regenerate-readme.sh` then `check-readme-discipline.sh`; surfaces remaining structural gaps as agent prompts.
- [x] 4.4 Author `images/default/config-overlay/opencode/agent/status.md` — runs `openspec list`; summarizes last 5 commits via `git log --oneline -5`; loads readme.traces tail; suggests next action.

## 5. OpenCode entrypoint shim

- [x] 5.1 Add the synthetic-first-prompt block to `images/default/entrypoint-forge-opencode.sh`: write `run /startup` to the OpenCode auto-prompt path; idempotent across container restarts.
- [x] 5.2 Verify `entrypoint-forge-claude.sh`, `entrypoint-forge-opencode-web.sh`, `entrypoint-terminal.sh` are NOT touched (the shim is OpenCode-only in v1).
- [x] 5.3 Update `images/default/Containerfile` (or `flake.nix`) to COPY the four skill files into `~/.config-overlay/opencode/agent/` at image build time.
- [x] 5.4 Update `images/default/Containerfile` to COPY the dispatcher + validator into `/usr/local/bin/`, the six summarizers into `/opt/summarizers/` (with symlinks under `/usr/local/bin/`), and the welcome cheatsheets into `cheatsheets/welcome/` (consumed by the existing cheatsheet COPY stage).

## 6. Pre-push git hook

- [x] 6.1 Author `scripts/install-readme-pre-push-hook.sh` (idempotent — checks for existing hook with same content and is a no-op; re-installs if content drift detected).
- [x] 6.2 The hook calls `regenerate-readme.sh && git add README.md && git diff --cached --quiet README.md || git commit --no-verify -m "chore(readme): regenerate at $(date -u -Iminutes)"`.
- [x] 6.3 The hook never blocks the push (any non-zero from regenerate is logged and swallowed; the push proceeds).
- [x] 6.4 `/startup` invokes the installer if `<project>/.git/hooks/pre-push` is missing or content-mismatched.

## 7. README.traces accumulator

- [x] 7.1 Define the schema as `{ts: ISO8601, agent: string, observation: string, severity: info|warn|regen-trigger}` in `cheatsheets/welcome/readme-discipline.md`.
- [x] 7.2 The dispatcher reads the latest 50 lines of `<project>/.tillandsias/readme.traces` (if present) and feeds them as context to the summary-rendering stage.
- [x] 7.3 `<project>/.tillandsias/readme.traces` is committed to the project's git (NOT gitignored) so cross-machine sessions inherit observations.
- [x] 7.4 The file is append-only — the dispatcher MUST NOT rewrite earlier lines.

## 8. Telemetry hooks (cheatsheet-telemetry extensions)

- [ ] 8.1 Extend the cheatsheet-telemetry event schema to support new `event_type` values: `startup_routing` (which branch was taken), `readme_regen` (which summarizers ran), `readme_requires_pull` (which required cheatsheet was materialized).
- [ ] 8.2 Add the new event types to `cheatsheets/runtime/external-logs.md`'s schema documentation.
- [ ] 8.3 The four skills emit telemetry at routing decision points and after dispatcher runs.

## 9. README requires_cheatsheets consumer

- [ ] 9.1 `/startup` parses the requires_cheatsheets YAML block from the project's README (after running `bootstrap-readme` if README is bad).
- [ ] 9.2 For each required cheatsheet, look up via cheatsheets-license-tiered tier classifier: bundled → already on disk; distro-packaged → already on disk; pull-on-demand → materialize via the recipe; missing-and-off-allowlist → emit WARN.
- [ ] 9.3 Materialization emits a `readme_requires_pull` telemetry event with `triggered_by: readme-requires`.

## 10. Migration of existing projects

- [ ] 10.1 Run `/bootstrap-readme` against Tillandsias itself; commit the generated README.
- [ ] 10.2 Verify the generated README round-trips through `check-readme-discipline.sh` with no errors.
- [ ] 10.3 Install the pre-push hook in Tillandsias; verify a `git push` produces a `chore(readme): regenerate at <ts>` commit.

## 11. Documentation + CLAUDE.md

- [ ] 11.1 Add a "Project README discipline" section to `CLAUDE.md` pointing at `cheatsheets/welcome/readme-discipline.md` and naming the four skills.
- [ ] 11.2 Update `docs/cheatsheets/` (host-side maintainer cheatsheets) with a new entry on the README discipline if a maintainer-relevant gotcha emerges during apply.
