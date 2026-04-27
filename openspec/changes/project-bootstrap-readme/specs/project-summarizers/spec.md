# project-summarizers Specification

@trace spec:project-summarizers, spec:project-bootstrap-readme

## ADDED Requirements

### Requirement: Per-language summarizer interface contract

A summarizer SHALL be an executable script (bash, python, or any other interpreted/compiled binary the forge image carries) that conforms to a uniform argv + stdio + exit-code contract so the dispatcher can invoke any summarizer without per-tool branching:

- **Argv**: zero or one positional argument. When zero, the script SHALL inspect the current working directory for its target manifest (e.g., `Cargo.toml`, `flake.nix`). When one, the argument is the absolute path to the project root to summarize.
- **Stdout**: markdown — typically 5–15 lines under one or more H3 sub-headings. The dispatcher concatenates stdout from each successful summarizer into the README's `## Tech Stack` and `## Build/Runtime Dependencies` sections.
- **Stderr**: free-form diagnostic messages. The dispatcher does not surface stderr to the README.
- **Exit code**: `0` if the summarizer's target manifest was found AND parsed successfully (output is on stdout). `>0` if the manifest is absent (the summarizer does NOT apply to this project). Any non-zero exit SHALL be treated as "skip", not as a failure of the dispatcher.

#### Scenario: Summarizer with manifest present exits zero

- **WHEN** `scripts/summarize-cargo.sh` runs in a project root containing `Cargo.toml`
- **THEN** stdout SHALL be non-empty markdown
- **AND** exit code SHALL be 0

#### Scenario: Summarizer with manifest absent exits non-zero

- **WHEN** `scripts/summarize-cargo.sh` runs in a project root containing no `Cargo.toml`
- **THEN** stdout SHALL be empty
- **AND** exit code SHALL be non-zero (2 by convention, signaling "not applicable")

#### Scenario: Argv with explicit project path

- **WHEN** `scripts/summarize-cargo.sh /tmp/some-other-project` runs
- **THEN** the summarizer SHALL inspect `/tmp/some-other-project/Cargo.toml`, not the current working directory's

### Requirement: Six initial summarizers in the forge image

The forge image SHALL ship six summarizer scripts under `/opt/summarizers/` (also symlinked into `/usr/local/bin/`) covering the languages most commonly seen in the project workspace:

| Path | Manifests inspected | Output emphasis |
|---|---|---|
| `/opt/summarizers/summarize-cargo.sh` | `Cargo.toml`, `Cargo.lock` | Workspace members, edition, top-level deps with versions |
| `/opt/summarizers/summarize-nix.sh` | `flake.nix`, `flake.lock` | Outputs (packages, devShells, apps), input pins |
| `/opt/summarizers/summarize-package-json.sh` | `package.json`, `package-lock.json` | `dependencies` + `devDependencies` summary |
| `/opt/summarizers/summarize-pubspec.sh` | `pubspec.yaml`, `pubspec.lock` | Flutter SDK pin, dart deps |
| `/opt/summarizers/summarize-go-mod.sh` | `go.mod`, `go.sum` | Module path, Go version, top-level requires |
| `/opt/summarizers/summarize-pyproject.sh` | `pyproject.toml`, `requirements.txt`, `uv.lock` | Build-backend, deps, optional `[tool.poetry]` |

Each summarizer SHALL be standalone (no inter-summarizer dependencies); each SHALL be idempotent (running twice with no project changes produces byte-identical stdout); each SHALL execute in under 5 seconds on a typical project.

#### Scenario: All six summarizers ship in the forge image

- **WHEN** the forge image is built
- **THEN** `/opt/summarizers/summarize-cargo.sh`, `summarize-nix.sh`, `summarize-package-json.sh`, `summarize-pubspec.sh`, `summarize-go-mod.sh`, and `summarize-pyproject.sh` SHALL exist
- **AND** each SHALL be executable (mode 0755)
- **AND** `/usr/local/bin/summarize-<lang>.sh` SHALL be a symlink to the corresponding `/opt/summarizers/` file

#### Scenario: Summarizer output round-trips through the dispatcher

- **WHEN** `scripts/regenerate-readme.sh` runs in a Tillandsias-style multi-language project (Rust + Nix)
- **THEN** the resulting README's `## Build/Runtime Dependencies` section SHALL contain the concatenation of `summarize-cargo.sh` and `summarize-nix.sh` outputs
- **AND** SHALL NOT contain output from summarizers whose manifests are absent

### Requirement: Project-local summarizer extension path

Projects with non-standard build systems MAY add summarizers under `<project>/.tillandsias/summarizers/`. The dispatcher SHALL run those AFTER the six built-in summarizers, with their stdout appended in alphabetical order. Project-local summarizers MUST conform to the same argv + stdio + exit-code contract.

#### Scenario: Project-local summarizer is invoked

- **WHEN** `<project>/.tillandsias/summarizers/summarize-bazel.sh` exists and is executable
- **AND** `scripts/regenerate-readme.sh` runs in that project
- **THEN** the summarizer SHALL be invoked
- **AND** its stdout SHALL be appended to the README's dependencies section AFTER the built-in summarizers' output

#### Scenario: Project-local summarizer ordering is stable

- **WHEN** `<project>/.tillandsias/summarizers/` contains `aaa.sh`, `bbb.sh`, `zzz.sh`
- **THEN** they SHALL be invoked in lexical order: `aaa.sh`, `bbb.sh`, `zzz.sh`

### Requirement: Dispatcher (regenerate-readme.sh) orchestrates summarizers

`scripts/regenerate-readme.sh` SHALL be the single entry point for README regeneration. It SHALL:

1. Detect the project root (walk upward from PWD until `.git/` is found).
2. Invoke each built-in summarizer with the project root as argv[1]. Capture stdout on success (exit 0); discard stdout and continue on non-zero exit.
3. Invoke project-local summarizers under `<project>/.tillandsias/summarizers/` in lexical order with the same argv contract.
4. Render the FOR HUMANS section (timestamp + ASCII art + install snippet + whimsical description).
5. Render the FOR ROBOTS section by concatenating summarizer outputs under `## Tech Stack` and `## Build/Runtime Dependencies`, then preserving any agent-curated `## Security`, `## Architecture`, `## Privacy` sections from the previous README, then appending `## Recent Changes` (last 10 commits + last build's commit if different) and `## OpenSpec — Open Items` (from `openspec list`) and the `requires_cheatsheets:` YAML block.
6. Write the result to `<project>/README.md`, atomically (write to `README.md.tmp`, then rename).

The dispatcher SHALL be idempotent: running twice with no project changes produces byte-identical output, except for the FOR HUMANS timestamp.

#### Scenario: Dispatcher walks upward to find project root

- **WHEN** `scripts/regenerate-readme.sh` runs in a deep subdirectory like `<project>/src/foo/bar/`
- **THEN** the dispatcher SHALL walk upward until a `.git/` directory is found
- **AND** SHALL treat that directory as the project root
- **AND** SHALL write README.md to that root

#### Scenario: Dispatcher write is atomic

- **WHEN** `scripts/regenerate-readme.sh` runs and produces output
- **THEN** the output SHALL be written to `<project>/README.md.tmp` first
- **AND** THEN renamed to `<project>/README.md` in a single rename(2) call
- **AND** a partial write (e.g., disk full) SHALL NOT corrupt the existing README.md

## Sources of Truth

- `cheatsheets/runtime/cheatsheet-tier-system.md` — pattern for tier-aware ecosystem documentation; summarizers are the project-side analogue
- `cheatsheets/build/distro-packaged-cheatsheets.md` (planned) — distro-packaged summarizers may eventually piggyback on package metadata
- `openspec/changes/project-bootstrap-readme/proposal.md` — origin of the per-language summarizer requirement
- `openspec/changes/project-bootstrap-readme/design.md` — Decision 4 (interface) and Decision 5 (dispatcher mechanics)
