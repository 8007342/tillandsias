# Onboarding Implementation Gaps Audit — 2026-05-14

**Iteration**: Wave 10 (implementation-gaps-backlog, order 8)
**Task**: implementation-gaps/onboarding
**Auditor**: Claude Code (Opus 4.7)
**Scope**: Comprehensive review of all completed onboarding work from order 4 (onboarding-and-discovery), Wave 8 — six granular tasks: welcome-banner, project-discovery, shell-tools, bootstrap-readme, remote-projects, auth-script

---

## Executive Summary

All six onboarding granular tasks are **production-ready for the happy path**: single repo, English locale, single workdir, fresh deploy key. The first-turn forge experience renders coherent welcome content, exposes 20+ project type detection, ships `tgs`/`tgp`/`cache-report` shell shortcuts, documents the FOR HUMANS / FOR ROBOTS README contract, surfaces remote project discovery independently of auth, and generates ed25519 deploy keys without leaking credentials.

Implementation gaps are bounded and concentrated in four areas:

1. **Internationalization surface** — welcome banner is localized to 17 locales, but downstream tooling (project-info MCP, shell shortcuts, remote-projects status hints) is English-only.
2. **Cold-start integration coverage** — the *components* exist; the *end-to-end first-turn agent story* is not litmus-bound.
3. **Edge-case project shapes** — multi-workdir (git worktree), nested polyrepos/monorepos, and symlinked project roots are not handled.
4. **Auth lifecycle gaps** — deploy key generation works once, but re-runs, revocation, and keyring-unavailability error surfacing are not implemented.

None of the gaps block the current release. All are tracked here as a dependency DAG so future agents can pick leaves without re-discovering blockers.

---

## Gap Dependency Graph

Gaps are modelled as a DAG (per the handoff convention: "onboarding gaps should remain graph-shaped, not linear guesswork"). Leaves can be implemented independently; non-leaf nodes require their dependencies first.

```
locale-coverage-i18n (parent)
├── gap-i18n-project-info-mcp                      [LEAF]
├── gap-i18n-shell-tools-output                    [LEAF]
└── gap-i18n-remote-projects-tray-status           [LEAF]

first-turn-cold-start-story (parent)
├── gap-cold-start-skill-discovery-litmus          [LEAF]
├── gap-readme-traces-ledger-creation-test         [LEAF]
├── gap-pre-push-hook-installation-litmus          [LEAF]
└── gap-requires-cheatsheets-ci-coverage           [LEAF]

multi-workspace-project-edge-cases (parent)
├── gap-multi-workdir-git-worktree-handling        [LEAF]
├── gap-nested-project-type-detection              [LEAF]
└── gap-symlinked-project-canonicalization         [LEAF]

agent-bootstrap-discoverability (parent)
└── gap-forge-welcome-cheatsheet-pointer           [LEAF]

auth-script-lifecycle (parent)
├── gap-deploy-key-collision-detection             [LEAF]
├── gap-deploy-key-revocation-companion            [LEAF]
└── gap-keyring-unavailability-error-message       [LEAF]
```

---

## Detailed Gap Audit

### Category: Internationalization (i18n)

#### Gap: i18n-project-info-mcp

**Status**: KNOWN
**Severity**: Low (functional in English; degrades silently for non-English locales)
**Component**: `images/default/config-overlay/mcp/project-info.sh`
**Description**:
- The MCP server emits English-only field names and error strings (`"File not found:"`, `"No matches found"`, `"Failed to list files"`, `"Unknown tool:"`).
- The JSON tool-list descriptions (`"List project files (max depth 3, max 100 files)"`, `"Discover available projects in ~/src/ (git repos)"`, …) are English-only.
- Locale bundle in `images/default/locales/` covers welcome banner strings but not MCP server strings.

**Impact**:
- Non-English agents reading tool output may not match patterns they were trained on.
- Hard-coded error literals make grep-based agent reasoning brittle across locales.

**Fix Path**:
- Extend locale bundle schema to cover MCP tool error strings (`L_PROJECT_INFO_FILE_NOT_FOUND`, `L_PROJECT_INFO_NO_MATCHES`, …).
- Source the same `/etc/tillandsias/locales/${_LOCALE}.sh` at the top of `project-info.sh`.
- Replace hard-coded literals with `${L_*:-default}` pattern (consistent with `forge-welcome.sh`).

**Spec Reference**: `forge-environment-discoverability` (no current locale requirement; would need amendment).

---

#### Gap: i18n-shell-tools-output

**Status**: KNOWN
**Severity**: Low
**Component**: `images/default/config-overlay/mcp/git-tools.sh` (cache_report_text, table headers)
**Description**:
- `cache_report_text()` prints English-only column headers: `Tier`, `Path`, `Size`, `Persists?`, and persistence labels `yes (RO)`, `yes (git)`, `no`.
- `tgs`/`tgp` shortcuts surface git output (which is git-locale-controlled), but wrapper messages like `"Not on any branch; cannot push"` are English-only.

**Impact**: Same as above — non-English users see mixed-locale output (some git messages localized by git itself, wrapper text English).

**Fix Path**: Mirror the locale bundle pattern; introduce `L_CACHE_REPORT_TIER`, `L_CACHE_REPORT_PERSISTS`, `L_GIT_TOOLS_NO_BRANCH`, …

**Spec Reference**: `forge-shell-tools` (no current locale requirement).

---

#### Gap: i18n-remote-projects-tray-status

**Status**: KNOWN
**Severity**: Low
**Component**: `crates/tillandsias-core/src/state.rs`, tray menu builder
**Description**:
- The contextual status line at the top of the tray menu surfaces English strings: `"Sign in to GitHub"`, `"GitHub unreachable — using cached list"`, etc. (per `remote-projects` spec text).
- Native GTK tray uses host locale for menu items only when explicitly translated; current implementation uses literals.

**Impact**: Non-English tray users see English status hints in an otherwise localized desktop environment.

**Fix Path**:
- Introduce a small `crates/tillandsias-core/src/i18n.rs` module that resolves tray status strings from a bundled table keyed by `LANG`.
- Source locale tables from the same upstream as `images/default/locales/*.sh` to keep tray and forge in sync.

**Spec Reference**: `remote-projects`, `tray-ux` (would need amendment for explicit i18n requirement).

---

### Category: First-Turn Cold-Start Story

#### Gap: cold-start-skill-discovery-litmus

**Status**: KNOWN
**Severity**: Medium (story exists; verification is missing)
**Component**: end-to-end agent onboarding flow (cheatsheets/welcome/readme-discipline.md, /startup, /bootstrap-readme, /status skills)
**Description**:
- The four bootstrap skills are documented in `CLAUDE.md` (Project README Discipline section).
- `scripts/regenerate-readme.sh`, `scripts/check-readme-discipline.sh`, and `scripts/install-readme-pre-push-hook.sh` all exist.
- **No litmus test** asserts: "an agent in a fresh forge can discover `/startup`, route to `/bootstrap-readme`, regenerate the README, and validate via `/status` within one session."

**Impact**:
- Drift risk: changes to skill registration, MCP server config, or cheatsheet index could silently break the first-turn flow.
- Cold-start agents in the wild may need to be told explicitly what to do (defeats "no-config first-turn" goal).

**Fix Path**:
- Author `litmus:onboarding-cold-start-shape` that:
  1. Starts a fresh forge container against a scratch project.
  2. Asserts the welcome banner is displayed.
  3. Asserts `$TILLANDSIAS_CHEATSHEETS/welcome/readme-discipline.md` exists and is readable.
  4. Asserts `/startup` skill is invokable and routes correctly.
  5. Asserts regenerate-readme.sh produces a valid FOR HUMANS / FOR ROBOTS structure.
- Bind to a new spec section or augment `forge-opencode-onboarding`.

**Spec Reference**: `forge-opencode-onboarding`, `project-bootstrap-readme`

---

#### Gap: readme-traces-ledger-creation-test

**Status**: KNOWN
**Severity**: Low
**Component**: `.tillandsias/readme.traces` (append-only JSONL ledger documented in CLAUDE.md)
**Description**:
- CLAUDE.md states: ".tillandsias/readme.traces — Append-only JSONL ledger of agent observations (committed to git, cross-machine)".
- No script auto-creates the ledger on first agent observation.
- No litmus test asserts the ledger schema (JSONL, expected event fields).

**Fix Path**:
- Add `scripts/append-readme-trace.sh` (or extend `regenerate-readme.sh`) to ensure the ledger exists.
- Author `litmus:readme-traces-schema-shape` validating jsonl schema and field set.

**Spec Reference**: `project-bootstrap-readme`

---

#### Gap: pre-push-hook-installation-litmus

**Status**: KNOWN
**Severity**: Low
**Component**: `scripts/install-readme-pre-push-hook.sh`
**Description**:
- Script exists and is invoked by CLAUDE.md guidance.
- **No litmus test** asserts: after invoking the installer, `.git/hooks/pre-push` exists, is executable, and successfully regenerates README on push.

**Fix Path**:
- Author `litmus:readme-pre-push-hook-installation-shape`.
- Verify: idempotent install, hook is executable, hook triggers README regen in a sandbox.

**Spec Reference**: `project-bootstrap-readme`

---

#### Gap: requires-cheatsheets-ci-coverage

**Status**: KNOWN
**Severity**: Low
**Component**: requires_cheatsheets YAML block in spec/cheatsheet frontmatter
**Description**:
- CLAUDE.md mentions a `readme_requires_pull` telemetry event: "Cheatsheet materialized from requires_cheatsheets YAML block".
- The materialization path is documented but not litmus-bound — no CI step verifies that requires_cheatsheets references resolve, cheatsheets are pulled, and the failure mode (missing cheatsheet) is reported.

**Fix Path**:
- Add CI step that walks all `requires_cheatsheets` blocks and asserts each referenced cheatsheet exists.
- Author `litmus:requires-cheatsheets-resolution-shape`.

**Spec Reference**: `project-bootstrap-readme`, `project-summarizers`

---

### Category: Multi-Workspace Project Edge Cases

#### Gap: multi-workdir-git-worktree-handling

**Status**: KNOWN
**Severity**: Low (niche but real)
**Component**: `images/default/config-overlay/mcp/project-info.sh` (`get_project_metadata`, `project_list`)
**Description**:
- `project-info.sh` checks `[ -d "$project_dir/.git" ]` to assert "this is a git repo".
- Git worktrees use `.git` as a *file* pointing to the parent worktree's `.git/worktrees/<name>` directory, not a directory.
- The current detection treats worktrees as non-git directories, hiding them from `project_list`.

**Impact**: Users running `git worktree add` for parallel feature branches won't see those worktrees in the tray's project list or discoverability tools.

**Fix Path**:
- Replace `[ -d "$project_dir/.git" ]` with `[ -e "$project_dir/.git" ]` (file or directory).
- Optionally: walk `git worktree list` from each detected worktree root to enumerate sibling worktrees.

**Spec Reference**: `forge-environment-discoverability`, `remote-projects`

---

#### Gap: nested-project-type-detection

**Status**: KNOWN
**Severity**: Low (niche; monorepo / polyrepo support)
**Component**: `detect_project_types` in `project-info.sh`
**Description**:
- Detection runs at `project_dir` only — nested directories like `subproj/Cargo.toml` are invisible.
- A monorepo with `frontend/package.json` + `backend/Cargo.toml` reports neither type unless the manifests are at the outer root.

**Impact**: Monorepo users get incorrect type lists; nested tools (e.g., a Rust workspace inside a Node app) are not surfaced.

**Fix Path**:
- Add a `--recursive` mode (or new MCP tool `project_types_recursive`) that walks the project tree with a depth limit (e.g., 3).
- Aggregate detected types into a structured tree response.

**Spec Reference**: `forge-environment-discoverability`

---

#### Gap: symlinked-project-canonicalization

**Status**: KNOWN
**Severity**: Low
**Component**: `detect_project_types` + scanner watched-root logic in `crates/tillandsias-scanner`
**Description**:
- If the watched directory (`~/src/`) contains a symlink pointing outside the watched root (e.g., `~/src/external-project → /opt/work/external-project`), detection follows the symlink.
- The same project may appear under both its canonical path and the symlink path in `project_list`, creating duplicates.

**Fix Path**:
- Canonicalize project paths via `readlink -f` before adding to the project list.
- Deduplicate by canonical path.

**Spec Reference**: `forge-environment-discoverability`

---

### Category: Agent Bootstrap Discoverability

#### Gap: forge-welcome-cheatsheet-pointer

**Status**: KNOWN
**Severity**: Medium (impacts cold-start agent discoverability)
**Component**: `images/default/forge-welcome.sh`
**Description**:
- The welcome banner shows project, OS, mounts, network, credentials, services, and a rotating tip.
- It does **not** point new agents at `$TILLANDSIAS_CHEATSHEETS/INDEX.md` or `$TILLANDSIAS_CHEATSHEETS/welcome/readme-discipline.md`.
- A cold-start agent without prior knowledge of the cheatsheet layout has no signal that the cheatsheet index exists.

**Impact**:
- Defeats the "no-config first-turn" goal for agents who don't already know the layout.
- The handoff note "do next agents find the first-turn story?" is currently *no*: they find the welcome banner and rotating tip, but not the structured onboarding cheatsheets.

**Fix Path**:
- Add one line to `forge-welcome.sh` near the rotating-tip block: `Agents: cat $TILLANDSIAS_CHEATSHEETS/INDEX.md | rg welcome`.
- Or add a dedicated `## Agent onboarding` row to the banner header with a single pointer.

**Spec Reference**: `forge-welcome`, `forge-opencode-onboarding`

---

### Category: Auth Script Lifecycle

#### Gap: deploy-key-collision-detection

**Status**: KNOWN
**Severity**: Low
**Component**: `scripts/generate-repo-key.sh --mode=deploy`
**Description**:
- Re-running `generate-repo-key.sh --mode=deploy --project=foo` overwrites any existing deploy key for `foo` in the keyring without confirmation.
- No `--force` flag exists; behaviour is implicitly "force" with no warning.

**Impact**: User may accidentally invalidate an active deploy key that GitHub still trusts.

**Fix Path**:
- Detect existing key via `secret-tool lookup` (or equivalent) before generation.
- Add explicit `--force` flag; print a warning if key exists and `--force` is absent.

**Spec Reference**: `gh-auth-script`, `secrets-management`

---

#### Gap: deploy-key-revocation-companion

**Status**: KNOWN
**Severity**: Low (lifecycle hygiene)
**Component**: missing `--mode=revoke` in `generate-repo-key.sh`
**Description**:
- The script generates keys and writes them to the keyring.
- No companion mode revokes a deploy key: remove from keyring + delete fingerprint reference from `.tillandsias/config.toml` + (optionally) call GitHub API to delete the deploy key.

**Impact**:
- Stale keys accumulate in the host keyring as projects age out.
- Users must manually run `secret-tool clear` + edit `.tillandsias/config.toml` + revoke on GitHub.

**Fix Path**:
- Add `--mode=revoke` that does the three-step cleanup.
- Add `--mode=rotate` that combines revoke + regenerate.

**Spec Reference**: `gh-auth-script`, `secret-rotation`

---

#### Gap: keyring-unavailability-error-message

**Status**: KNOWN
**Severity**: Low
**Component**: `scripts/generate-repo-key.sh` (Linux Secret Service via D-Bus)
**Description**:
- On headless Linux systems without a running Secret Service daemon, the script exits with code 3 ("keyring write failed") but doesn't explain the user-facing fix.
- The exit code is documented but the error message doesn't suggest "install gnome-keyring or pass" or "ensure D-Bus session bus is running".

**Impact**: Users on minimal Linux installs hit cryptic errors with no guidance.

**Fix Path**:
- Probe for D-Bus session bus availability before attempting keyring write.
- If unavailable, print actionable hint: "Secret Service not available. Install gnome-keyring or pass, or set DBUS_SESSION_BUS_ADDRESS."

**Spec Reference**: `gh-auth-script`, `native-secrets-store`

---

## Verification of Completed Work

The following were verified as **working** during this audit:

| Component                            | Verification                                                                   |
|--------------------------------------|--------------------------------------------------------------------------------|
| forge-welcome banner content         | `images/default/forge-welcome.sh` renders project, OS, mounts, tips           |
| Locale coverage (welcome banner)     | 17 locale files in `images/default/locales/` (ar, de, en, es, fr, hi, it, ja, ko, nah, pt, ro, ru, ta, te, zh-Hans, zh-Hant) |
| Project type detection (20+ types)   | `detect_project_types()` covers Rust, Go, Node (4 variants), Python (5 variants), Java (2), CMake, Make, Docker, Nix, Dart, git, plus polyglot composition |
| MCP `project_list` / `project_info`  | Both tools exposed via stdio MCP server                                        |
| `tgs`/`tgp` shell shortcuts          | Wired through `images/default/config-overlay/mcp/git-tools.sh`                |
| `cache-report` shortcut              | Renders tier table per `forge-cache-dual` spec                                 |
| FOR HUMANS / FOR ROBOTS contract     | Documented in `cheatsheets/welcome/readme-discipline.md` (8-step structure)   |
| Remote projects auth independence    | Spec verified: `Remote Projects ▸` hidden when auth missing (no placeholder)  |
| `generate-repo-key.sh --mode=deploy` | Generates ed25519, stores private key in keyring, writes fingerprint to config|
| `generate-repo-key.sh --mode=gpg`    | Legacy GPG mode retained for older release scripts                            |
| @trace coverage                       | All onboarding scripts annotated with `@trace spec:<name>`                    |

---

## Conclusion

Onboarding is **shippable as-is**. Gaps documented here are explicit, bounded, and modelled as a DAG so a future agent can pick any leaf without re-auditing. The most user-visible gap is `forge-welcome-cheatsheet-pointer` (Medium severity); the most lifecycle-relevant is `deploy-key-revocation-companion`; everything else is Low severity.

Recommend: pick one leaf per future wave rather than batching, so each gap closure is independently testable. The DAG structure ensures parallel agents can claim non-overlapping leaves.

---

**Handoff anchors**:
- Commit: `97dd30d2` (HEAD on `linux-next`)
- Branch: `linux-next`
- Plan step: `plan/steps/04-onboarding-docs.md`
- Dependency tail: `implementation-gaps/observability` (next plan node)
