# spec: project-summarizers

## Status

active

## Overview

Define the language-specific manifest summarizer scripts that extract project metadata from authoritative sources (Cargo.toml, package.json, pom.xml, etc.). These summarizers provide the data foundation for README auto-generation and project discovery.

@trace spec:project-summarizers

## Requirements

### Requirement: Summarizers MUST parse manifest files deterministically

Each language-specific summarizer MUST read the project manifest and extract key metadata in a consistent, machine-readable format.

#### Scenario: Cargo summarizer parses Rust project
- **WHEN** `scripts/summarizers/summarize-cargo.sh` is executed on a Rust project
- **THEN** it reads `Cargo.toml` and extracts:
  - `name` — package name
  - `version` — semantic version
  - `description` — one-line summary
  - `authors` — list of authors
  - `dependencies` — list of direct dependencies with versions
  - `main` or `bin` — entry point
- **AND** output is JSON or YAML on stdout
- **AND** the extraction is deterministic (same Cargo.toml → same output)

#### Scenario: Package.json summarizer parses Node.js project
- **WHEN** `scripts/summarizers/summarize-package-json.sh` is executed
- **THEN** it reads `package.json` and extracts:
  - `name`, `version`, `description`, `main`, `scripts`, `dependencies`, `devDependencies`
  - `keywords` — topic tags
  - `license` — SPDX identifier
  - Node.js version requirement (from `engines.node`)

#### Scenario: Maven summarizer parses Java project
- **WHEN** `scripts/summarizers/summarize-maven.sh` is executed
- **THEN** it reads `pom.xml` and extracts:
  - `groupId`, `artifactId`, `version`
  - `name`, `description`
  - `properties` (e.g., `maven.compiler.source`)
  - Direct dependencies (from `<dependencies>`)
  - Java version requirement

#### Scenario: Gradle summarizer parses Java project
- **WHEN** `scripts/summarizers/summarize-gradle.sh` is executed
- **THEN** it reads `build.gradle` or `build.gradle.kts` and extracts:
  - Project name, version, group
  - Dependencies (from `dependencies {}` block)
  - Java version requirement
  - Build output (from `jar` or `application` plugins)

#### Scenario: Flutter summarizer parses Flutter project
- **WHEN** `scripts/summarizers/summarize-flutter.sh` is executed
- **THEN** it reads `pubspec.yaml` and extracts:
  - `name`, `version`, `description`
  - `environment.sdk` — Flutter SDK version requirement
  - Direct dependencies (from `dependencies` and `dev_dependencies`)

#### Scenario: Go summarizer parses Go project
- **WHEN** `scripts/summarizers/summarize-go.sh` is executed
- **THEN** it reads `go.mod` and extracts:
  - Module path
  - Go version requirement
  - Direct dependencies with versions
  - (Optional) reads `go.sum` for transitive dependency count

### Requirement: Summarizers MUST output structured, consistent data

All summarizers MUST produce output in a unified structured format (JSON recommended).

#### Scenario: Consistent output schema
- **WHEN** any summarizer is executed
- **THEN** the output includes at minimum:
  ```json
  {
    "project_type": "rust|go|node|java-maven|java-gradle|flutter",
    "name": "project-name",
    "version": "1.2.3",
    "description": "one-line summary",
    "main_entry": "path/to/main.rs or main.go or package.json#main",
    "dependencies_count": 12,
    "languages": ["rust", "toml"],
    "last_modified": "2026-05-03T12:34:56Z"
  }
  ```
- **AND** the JSON is valid and parseable with `jq`
- **AND** keys are consistent across all summarizers (same key names for equivalent concepts)

#### Scenario: Summarizers handle missing files gracefully
- **WHEN** a summarizer is executed but the manifest file doesn't exist
- **THEN** it emits a JSON error object with `"error": "Cargo.toml not found"`
- **AND** returns exit code 1

### Requirement: Summarizers MUST be embeddable as shell scripts

All summarizers MUST be standalone shell scripts with no external runtime dependencies (beyond common CLI tools like `jq`, `sed`).

#### Scenario: Summarizer embedded in binary
- **WHEN** `src-tauri/src/embedded.rs` is compiled
- **THEN** the summarizer scripts are included via `include_str!`
- **AND** they are written to a temp directory and executed as needed

#### Scenario: Summarizer execution within the tray
- **WHEN** the tray generates README content
- **THEN** it can invoke summarizers without spawning external containers
- **AND** performance is acceptable for real-time regeneration

### Requirement: README dispatcher orchestrates all summarizers

A master dispatcher script MUST invoke the appropriate summarizers based on project type detection.

#### Scenario: Auto-detection of project type
- **WHEN** `scripts/regenerate-readme.sh` runs in a project directory
- **THEN** it auto-detects the project type by checking for manifest files:
  - Presence of `Cargo.toml` → Rust
  - Presence of `go.mod` → Go
  - Presence of `package.json` → Node.js
  - Presence of `pom.xml` → Maven
  - Presence of `build.gradle` or `build.gradle.kts` → Gradle
  - Presence of `pubspec.yaml` → Flutter
  - Multiple manifests → multi-language project (e.g., Rust + Node.js)

#### Scenario: Dispatcher runs appropriate summarizers
- **WHEN** a multi-language project is detected
- **THEN** the dispatcher runs all applicable summarizers
- **AND** aggregates the results into a single README
- **AND** includes a "Technologies" section listing all detected languages

#### Scenario: Dispatcher handles unknown project types
- **WHEN** no manifest files are detected
- **THEN** the dispatcher outputs a minimal README template
- **AND** warns: "No manifest detected; README is a template — please customize manually"

## Implementation Notes

This spec is created retroactively as part of the traces-audit refactor. It may represent:
- An abandoned initiative that was never fully spec'd
- A feature whose spec was lost or mishandled
- A trace annotation that should have been corrected instead

## Sources of Truth

- `cheatsheets/runtime/podman.md` — Podman reference and patterns
- `cheatsheets/architecture/event-driven-basics.md` — Event Driven Basics reference and patterns

## Observability

```bash
git log --all --grep="project-summarizers" --oneline
git grep -n "@trace spec:project-summarizers"
```

