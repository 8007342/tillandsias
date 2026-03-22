## Context

The `images/default/opencode.json` was written with a placeholder provider/model (`opencode/big-pickle`) that was never part of any OpenCode release. This config is copied into the container at build time as `/home/forge/.opencode.json`. When OpenCode reads it at startup, it fails to find the referenced model and exits with "agent coder not found".

## Goals / Non-Goals

**Goals:**
- Make the container start successfully by removing the broken provider/model config
- Preserve the useful parts of the config (tool enablement, permissions)
- Make the entrypoint resilient to OpenCode launch failures

**Non-Goals:**
- Configuring a specific AI provider or model (that is the user's responsibility at runtime)
- Changing the Containerfile build process
- Modifying any Rust code

## Decisions

### D1: Minimal opencode.json with tools and permissions only

Remove the `provider`, `model`, and `$schema` fields entirely. Keep only `tools` and `permissions`. This lets OpenCode use its own built-in defaults for provider and model selection, which is the correct behavior for a generic container image that does not know what backend the user will connect to.

### D2: Entrypoint fallback on OpenCode failure

Change the entrypoint to attempt launching OpenCode and, if it exits with a non-zero status, fall back to bash with a diagnostic message. This prevents a broken config (or any other OpenCode issue) from making the container completely inaccessible. The welcome banner is updated to show clearly whether OpenCode launched or the fallback activated.
