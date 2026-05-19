# Step 04: Onboarding, Discoverability, and Repo Bootstrap Docs

## Status

completed (with documented gaps — see § Implementation Gaps below)

## Objective

Keep the first-turn forge experience validator-clean and make project discovery explain itself without duplicating old launch contracts.

## Included Specs

- `forge-welcome`
- `forge-shell-tools`
- `forge-environment-discoverability`
- `forge-opencode-onboarding`
- `default-image`
- `project-bootstrap-readme`
- `project-summarizers`
- `remote-projects`
- `gh-auth-script`

## Deliverables

- A coherent onboarding sequence that points at the real source of truth.
- README/bootstrap tooling that is explicit about whether it is live behavior or historical distillation.
- Any historical onboarding placeholder tombstoned cleanly.

## Verification

- Narrow onboarding/docs litmus chain.
- `./build.sh --ci --strict --filter <onboarding-bundle>`
- `./build.sh --ci-full --install --strict --filter <onboarding-bundle>`

## Clarification Rule

- If the spec is only a retroactive artifact, mark it obsolete rather than trying to synthesize live behavior from it.

## Granular Tasks

- `onboarding/welcome-banner` — completed (commit `f44a8a61` regenerated traces; locale bundle in `images/default/locales/` covers 17 locales)
- `onboarding/project-discovery` — completed (commit `14b947fd`; 20+ marker files detected via `images/default/config-overlay/mcp/project-info.sh`)
- `onboarding/shell-tools` — completed (commit `916588af`; `tgs`/`tgp`/`cache-report` shortcuts wired into `git-tools.sh`)
- `onboarding/bootstrap-readme` — completed (commit `9ddeb7ad`; `cheatsheets/welcome/readme-discipline.md` defines FOR HUMANS / FOR ROBOTS structure)
- `onboarding/remote-projects` — completed (spec live; `gh repo list --json name,url --limit 100` invoked via forge per spec)
- `onboarding/auth-script` — completed (commit `274105be`; `scripts/generate-repo-key.sh` supports `--mode=gpg` and `--mode=deploy`, private key never leaves keyring)

## Exit Criteria

- [x] The first-turn story is coherent and validator-clean (welcome banner → discoverability → shell tools).
- [x] Retrofit specs are either live, bounded, or tombstoned if historical.
- [x] Welcome banner renders project, OS, mounts, network, credentials, rotating tip (per `forge-welcome` spec).
- [x] Project discovery enumerates 20+ project types via marker files (`Cargo.toml`, `package.json`, `go.mod`, `pyproject.toml`, `pubspec.yaml`, …) and emits polyglot type lists (sorted-unique).
- [x] Shell shortcuts `tgs`, `tgp`, `cache-report` exist and route through the same MCP primitives as agent calls (`images/default/config-overlay/mcp/git-tools.sh`).
- [x] README discipline cheatsheet enumerates FOR HUMANS + FOR ROBOTS contract and is referenced by `/startup`, `/bootstrap-readme`, `/status` skills (cheatsheets/welcome/readme-discipline.md).
- [x] Remote project discovery is independent of GitHub auth (auth missing → `Remote Projects ▸` submenu hidden, status line surfaces resolution).
- [x] `generate-repo-key.sh` produces an ed25519 deploy key, stores private key only in host keyring (Secret Service / Keychain), and writes only public-key fingerprint to `.tillandsias/config.toml`.
- [ ] **Gap acknowledged**: locale coverage of project-info.sh, shell-tools output, and remote-projects status strings (see § Implementation Gaps).
- [ ] **Gap acknowledged**: first-turn agent cold-start story not fully integration-tested end-to-end (see § Implementation Gaps).

## Implementation Gaps

This is the integrative "close the loop" review for Wave 10. Gaps are **documented, not fixed**. Each is modelled as a node in a dependency graph so future agents can pick leaves without re-discovering blockers. Detailed gap audit lives in `plan/issues/onboarding-gaps-2026-05-14.md`.

### Gap graph (dependency-ordered, leaves first)

```
locale-coverage-i18n
   ├── welcome-banner-locales (17 locales present, covered)
   ├── project-discovery-locale-strings (gap: hard-coded English in MCP server)
   ├── shell-tools-locale-strings (gap: hard-coded English in cache-report output)
   └── remote-projects-locale-strings (gap: tray status line uses English literals)

first-turn-cold-start-story
   ├── welcome-banner-integration (covered: rendered on terminal launch)
   ├── project-discovery-discoverability (covered: project_info MCP tool)
   ├── agent-finds-readme-discipline (gap: requires_cheatsheets pull untested in CI)
   └── agent-finds-skills-on-cold-start (gap: /startup, /bootstrap-readme skill invocation path not litmus-tested)

multi-workspace-project-edge-cases
   ├── multi-workdir-detection (gap: project_info.sh assumes single workdir; git worktree not handled)
   ├── nested-project-handling (gap: a project containing `subproj/Cargo.toml` reports parent type only)
   └── symlinked-project-handling (gap: symlinked source roots may break `detect_project_types` if symlink target is outside watched root)

auth-script-edge-cases
   ├── keyring-write-failure-recovery (covered: exit code 3 documented)
   ├── existing-deploy-key-collision (gap: re-running `--mode=deploy` overwrites without warning)
   └── revocation-workflow (gap: no companion script to revoke or rotate a deploy key)
```

### High-level gap categories

1. **Internationalization (i18n)** — Welcome banner is fully localized (17 locales: ar, de, en, es, fr, hi, it, ja, ko, nah, pt, ro, ru, ta, te, zh-Hans, zh-Hant). The downstream onboarding surfaces are NOT localized:
   - `project-info.sh` MCP tool emits hard-coded English JSON fields and error strings.
   - `git-tools.sh` shell shortcuts (`cache-report`, `tgs`, `tgp`) print English-only column headers and status lines.
   - `remote-projects` tray submenu and status hints (e.g., "Sign in to GitHub", "GitHub unreachable — using cached list") are English-only.

2. **First-turn cold-start completeness** — The agent-onboarding story is *structurally* present (welcome banner runs on terminal launch; `requires_cheatsheets` pulls work) but is not end-to-end *integration-tested*:
   - No litmus test verifies an agent in a fresh forge can discover `/startup`, follow it to `/bootstrap-readme`, regenerate the README, and validate via `/status` within one session.
   - The `readme.traces` ledger (`.tillandsias/readme.traces`) is documented but no test asserts it is created on first push.
   - Pre-push hook installation (`scripts/install-readme-pre-push-hook.sh`) is documented but not litmus-bound.

3. **Multi-workdir / nested / symlinked project edge cases** — `images/default/config-overlay/mcp/project-info.sh` uses `[ -f $project_dir/<marker> ]` directly:
   - Multi-workdir (git `worktree`) projects: the worktree root is reported as the project root, ignoring sibling worktrees.
   - Nested projects: a polyrepo or monorepo with `subdir/Cargo.toml` reports only the outer project type; nested project types are invisible.
   - Symlinked projects: if the watched dir contains a symlink pointing outside the watched root, `detect_project_types` follows the symlink, but discovery results are not deduplicated against the canonical project.

4. **Agent-facing onboarding discoverability** — The "next agent" handoff story relies on `cheatsheets/welcome/readme-discipline.md`, but no automation surfaces this cheatsheet to a fresh agent unless the agent already knows to look for `/opt/cheatsheets/INDEX.md`. Need: a one-line bootstrap hint in `forge-welcome.sh` (currently absent) that points new agents at `$TILLANDSIAS_CHEATSHEETS/welcome/`.

5. **Auth script edge cases** — `generate-repo-key.sh --mode=deploy` does not:
   - Detect existing deploy keys in the keyring before overwriting (no `--force` confirmation).
   - Provide a revocation companion (no `--mode=revoke` to remove the key from keyring + GitHub).
   - Surface keyring D-Bus unavailability with a clear user-facing error (Linux Secret Service may be missing on headless systems).

### Why these gaps remain open

These are *post-MVP refinements*. The first-turn forge experience is coherent and validator-clean for the typical happy path (single repo, English locale, single workdir, fresh deploy key). The gaps above target:
- Multi-locale users (i18n surface).
- Polyrepo / monorepo / worktree users (edge-case detection).
- Multi-deploy-key projects (key rotation lifecycle).
- Cold-start agents who haven't yet discovered the cheatsheet index (bootstrap discoverability).

None block the current release. All are tracked in `plan/issues/onboarding-gaps-2026-05-14.md` for future waves.

## Handoff

- Assume the next agent may be different.
- Notes should explain the current branch, file scope, checkpoint SHA, residual risk, and the next dependency tail.
- Reapplying the same update must not create duplicate meaning.
- **Cold-start note**: Onboarding implementation is complete; remaining work is gap closure. Pick leaves from the gap graph above rather than re-auditing the step. The detailed gap audit (`plan/issues/onboarding-gaps-2026-05-14.md`) carries severity, impact, and fix paths for every node.
