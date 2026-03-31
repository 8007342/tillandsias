## Context

The accountability window system (from `logging-accountability-framework`) outputs lines like:

```
[secrets] v0.1.97.76 | Token written for tillandsias-tetris-aeranthos -> /run/secrets/... (tmpfs, ro mount)
  Spec: secret-rotation
  Cheatsheet: docs/cheatsheets/token-rotation.md
```

The "Spec:" line links to the OpenSpec design document (via the spec name). The "Cheatsheet:" line links to a human-readable reference document that explains the mechanism in plain language. Both links are relative paths within the repository, so a developer with a local checkout can open them directly.

## Goals / Non-Goals

**Goals:**
- Three cheatsheet documents covering the three main accountability-visible subsystems
- Each cheatsheet is self-contained: a reader does not need to read the OpenSpec design docs to understand the mechanism
- Consistent format across all cheatsheets for scanability
- Written for the "developer debugging a problem" audience: concise, step-by-step, with failure modes
- Cross-referenced with specs and source files

**Non-Goals:**
- User-facing documentation (AJ-level). Cheatsheets are for developers and auditors.
- Exhaustive API documentation (that belongs in rustdoc)
- Replacing the OpenSpec design documents (cheatsheets summarize, designs justify)
- Auto-generation from source (cheatsheets are hand-written for clarity)

## Decisions

### D1: Cheatsheet format

**Choice:** Every cheatsheet follows this template:

```markdown
# <Title>

## Overview
One paragraph explaining what this subsystem does and why it exists.

## How It Works
Numbered step-by-step description of the mechanism. Each step includes:
- What happens
- Which source file is responsible
- Which spec governs this step

## CLI Commands
How to observe this subsystem in action via CLI flags.

## Failure Modes
Table of what can go wrong, the symptom, and the recovery.

## Security Model
What is protected, what is not protected, and why.

## Related
- Specs: links to OpenSpec design documents
- Source: key source files
- Cheatsheets: cross-references to related cheatsheets
```

**Why:** Consistency makes cheatsheets scannable. The "How It Works" section is the core — it answers "what is happening?" which is the question driving someone to open the cheatsheet from an accountability log.

### D2: Three initial cheatsheets

**Choice:**

| Cheatsheet | Covers | Referenced by |
|------------|--------|---------------|
| `secret-management.md` | Full secret lifecycle: keyring, token files, mounts, cleanup | `--log-secret-management` accountability output |
| `logging-levels.md` | The six modules, log levels, accountability windows, example commands | All `--log-*` help text and output |
| `token-rotation.md` | Token refresh task, tmpfs storage, GIT_ASKPASS, path to App tokens | `--log-secret-management` token rotation events |

**Why:** These map 1:1 to the accountability windows and the two major subsystem changes (`logging-accountability-framework`, `secret-rotation-tokens`). Future cheatsheets for `--log-image-management` and `--log-update-cycle` will be added when those accountability windows are implemented.

### D3: Location under `docs/cheatsheets/`

**Choice:** All cheatsheets live at `docs/cheatsheets/<name>.md` in the repository root.

**Why:** The `docs/` directory is the conventional location for project documentation. Keeping cheatsheets in a subdirectory separates them from architecture docs, cross-platform build docs, etc. The path `docs/cheatsheets/secret-management.md` is short enough to include in accountability log output without line-wrapping.

### D4: Content scope for each cheatsheet

#### `secret-management.md`
- Overview of the three secret types: GitHub OAuth token, Claude API key, git identity
- Keyring storage: what goes in the keyring, how it's accessed, what happens when keyring is locked
- Token file lifecycle: write to tmpfs, mount into container, refresh, delete
- hosts.yml dual-path: why it exists, when it will be removed
- Container mount strategy: what gets mounted where, what is read-only, what is excluded
- OpenCode deny list: how `/run/secrets/` is blocked from AI agent access

#### `logging-levels.md`
- The six module names and what each covers
- The five log levels and when to use each
- How to use `--log=module:level;module:level` syntax
- How accountability windows work: `--log-secret-management`, etc.
- How to combine `--log` with `--log-*` flags
- Where log files live: `~/.local/state/tillandsias/tillandsias.log`
- How to share logs for support (strip secrets — though logs should never contain them)

#### `token-rotation.md`
- Why tokens should be short-lived (even though OAuth tokens are not)
- How the 55-minute refresh task works
- What GIT_ASKPASS is and how the helper script works
- The atomic write mechanism (write .tmp, rename)
- The three-layer cleanup strategy (container stop, app exit, Drop guard)
- Failure modes: keyring unavailable, tmpfs full, rename failure
- Roadmap: how this connects to the GitHub App token future

## Open Questions

1. **Should cheatsheets include source code snippets?** Pro: makes them self-contained. Con: code snippets go stale. **Leaning toward: minimal code, link to source files instead. Use pseudocode for step-by-step explanations.**

2. **Should cheatsheets be versioned (updated with each release)?** The cheatsheets describe mechanisms, not APIs. They should be updated when the mechanism changes, not on every version bump. **Decision: update cheatsheets when the corresponding spec changes. The version in the accountability output tells the reader which release they're running.**
