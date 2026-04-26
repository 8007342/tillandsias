## Why

Per `~/src/java/ENVIRONMENT_REPORT.md`: a model attempting to use the forge concluded "Java/JDK: Not installed in PATH … Maven Central URLs return 404/403 … RxJava JAR must be committed to repository." The forge actually ships `java-21-openjdk-devel`, `maven`, `gradle`, `flutter`, `cargo`, `rustup`, `go`, `python3`, `nodejs`, `pipx`, and 30+ utilities — but the model never discovered any of them. The discoverability gap turns a fully loaded forge into an empty Fedora box from the agent's seat.

This change makes the forge's tool surface immediately discoverable via THREE complementary mechanisms (per the user's "AND not OR" rule): (1) image-baked CLI commands the agent can run, (2) environment variables the agent's tool surface enumerates, (3) cheatsheets the methodology references on first turn.

## What Changes

- **NEW** `tillandsias-inventory` — bash command baked at `/opt/agents/tillandsias-cli/bin/tillandsias-inventory`. Lists every runtime + version. Default plain-text columns, `--json` flag for machine consumption.
- **NEW** `tillandsias-services` — bash command. Parses `/opt/cheatsheets/web/<service>.md` (or a dedicated `services.md`) and prints the discoverable enclave services + ports + status.
- **NEW** `tillandsias-models` — bash command. Curls the inference container's `/api/tags`, prints loaded ollama models with their tier annotation.
- **NEW** Env vars exported by the entrypoint: `TILLANDSIAS_IMAGE_VERSION` (image build version), `TILLANDSIAS_CAPABILITIES` (comma-separated capability list: `cargo,go,java-21,maven,gradle,flutter,nix,headless-chromium,...`).
- **MODIFIED** `images/default/forge-welcome.sh` enumerates one short row per category of the loaded runtimes (not just the cheatsheet hint). Three-line addition: "Languages: rust, go, java 21, python 3.13, node 22, dart 3 (flutter)" / "Build: cargo, maven, gradle, npm, nix, make, cmake, ninja" / "Test: pytest, junit, cargo-test, chromium-headless, firefox, chromedriver, geckodriver".
- The `tillandsias-inventory` command is the canonical source — the welcome banner is the at-a-glance summary.

## Capabilities

### New Capabilities
- `forge-inventory-cli` — the three commands + JSON contract.

### Modified Capabilities
- `default-image`: bakes the inventory binaries.
- `forge-welcome`: enumerates loaded tools by category.
- `environment-runtime`: new `TILLANDSIAS_IMAGE_VERSION` + `TILLANDSIAS_CAPABILITIES` env vars.

## Impact

- 3 new bash scripts in `images/default/cli/` (or similar) — total ≤ 300 LOC. All zero-dep (use coreutils, jq, curl).
- Containerfile copies them into `/opt/agents/tillandsias-cli/bin/` with `+x`.
- Welcome banner +3 lines.
- `TILLANDSIAS_IMAGE_VERSION` set at image build time via Containerfile `ARG` + `ENV`.
- `TILLANDSIAS_CAPABILITIES` enumerated by the inventory binary on first invocation OR set statically in Containerfile (favor static — agents shouldn't have to invoke a binary just to read an env var).
- No tray UX changes. No prompts. Pure agent-facing.

## Sources of Truth

- `cheatsheets/runtime/forge-paths-ephemeral-vs-persistent.md` — the inventory commands respect the path model.
- `cheatsheets/runtime/cheatsheet-architecture-v2.md` — discoverable cheatsheets work alongside discoverable tools.
- `~/src/java/ENVIRONMENT_REPORT.md` — the audit that motivated this change (Tillandsias-internal source).
