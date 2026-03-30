# Trace Index

Generated automatically from `@trace` comments in the codebase.
Run `./scripts/generate-traces.sh` to regenerate.

| Trace | Spec | Source Files |
|-------|------|--------------|
| `spec:app-lifecycle` | [app-lifecycle/spec.md](openspec/specs/app-lifecycle/spec.md) | [desktop.rs](src-tauri/src/desktop.rs#L10) |
| `spec:build-lock` | [build-lock/spec.md](openspec/specs/build-lock/spec.md) | [build_lock.rs](src-tauri/src/build_lock.rs#L6), [build_lock.rs](src-tauri/src/build_lock.rs#L79) |
| `spec:clickable-trace-index` | [clickable-trace-index/spec.md](openspec/changes/clickable-trace-index/specs/clickable-trace-index/spec.md) | [generate-traces.sh](scripts/generate-traces.sh#L18) |
| `spec:cli-mode` | [cli-mode/spec.md](openspec/specs/cli-mode/spec.md) | [runner.rs](src-tauri/src/runner.rs#L7) |
| `spec:default-image` | [default-image/spec.md](openspec/specs/default-image/spec.md) | [build-image.sh](scripts/build-image.sh#L17), [build-image.sh](scripts/build-image.sh#L225), [embedded.rs](src-tauri/src/embedded.rs#L11), [handlers.rs](src-tauri/src/handlers.rs#L29), [handlers.rs](src-tauri/src/handlers.rs#L55), [runner.rs](src-tauri/src/runner.rs#L7) |
| `spec:dev-build` | [dev-build/spec.md](openspec/specs/dev-build/spec.md) | [build.sh](build.sh#L24) |
| `spec:embedded-scripts` | [embedded-scripts/spec.md](openspec/specs/embedded-scripts/spec.md) | [embedded.rs](src-tauri/src/embedded.rs#L11), [embedded.rs](src-tauri/src/embedded.rs#L126) |
| `spec:environment-runtime` | [environment-runtime/spec.md](openspec/specs/environment-runtime/spec.md) | [container_profile.rs](crates/tillandsias-core/src/container_profile.rs#L11), [container_profile.rs](crates/tillandsias-core/src/container_profile.rs#L159), [launch.rs](src-tauri/src/launch.rs#L13) |
| `spec:filesystem-scanner` | [filesystem-scanner/spec.md](openspec/specs/filesystem-scanner/spec.md) | [lib.rs](crates/tillandsias-scanner/src/lib.rs#L1) |
| `spec:init-command` | [init-command/spec.md](openspec/specs/init-command/spec.md) | [init.rs](src-tauri/src/init.rs#L7) |
| `spec:knowledge-source-of-truth` | [knowledge-source-of-truth/spec.md](openspec/changes/add-knowledge-source-of-truth/specs/knowledge-source-of-truth/spec.md) | [fetch-debug-source.sh](scripts/fetch-debug-source.sh#L4) |
| `spec:native-secrets-store` | [native-secrets-store/spec.md](openspec/specs/native-secrets-store/spec.md) | [secrets.rs](src-tauri/src/secrets.rs#L22), [secrets.rs](src-tauri/src/secrets.rs#L45) |
| `spec:nix-builder` | [nix-builder/spec.md](openspec/specs/nix-builder/spec.md) | [build-image.sh](scripts/build-image.sh#L17), [build-image.sh](scripts/build-image.sh#L184) |
| `spec:podman-orchestration` | [podman-orchestration/spec.md](openspec/specs/podman-orchestration/spec.md) | [container_profile.rs](crates/tillandsias-core/src/container_profile.rs#L11), [launch.rs](crates/tillandsias-podman/src/launch.rs#L1), [lib.rs](crates/tillandsias-podman/src/lib.rs#L1), [lib.rs](crates/tillandsias-podman/src/lib.rs#L51), [lib.rs](crates/tillandsias-podman/src/lib.rs#L74), [event_loop.rs](src-tauri/src/event_loop.rs#L6), [event_loop.rs](src-tauri/src/event_loop.rs#L72), [handlers.rs](src-tauri/src/handlers.rs#L29), [launch.rs](src-tauri/src/launch.rs#L13), [launch.rs](src-tauri/src/launch.rs#L41), [launch.rs](src-tauri/src/launch.rs#L55), [launch.rs](src-tauri/src/launch.rs#L119), [runner.rs](src-tauri/src/runner.rs#L7) |
| `spec:tray-app` | [tray-app/spec.md](openspec/specs/tray-app/spec.md) | [event_loop.rs](src-tauri/src/event_loop.rs#L6), [event_loop.rs](src-tauri/src/event_loop.rs#L72), [handlers.rs](src-tauri/src/handlers.rs#L29), [menu.rs](src-tauri/src/menu.rs#L21) |
| `spec:tray-icon-lifecycle` | [(archived) tray-icon-lifecycle/spec.md](openspec/changes/archive/2026-03-30-tray-icon-lifecycle/specs/tray-icon-lifecycle/spec.md) | [build.rs](crates/tillandsias-core/build.rs#L49), [build.rs](crates/tillandsias-core/build.rs#L221), [genus.rs](crates/tillandsias-core/src/genus.rs#L237), [state.rs](crates/tillandsias-core/src/state.rs#L230), [main.rs](src-tauri/src/main.rs#L156), [main.rs](src-tauri/src/main.rs#L175), [main.rs](src-tauri/src/main.rs#L425) |
| `spec:versioning` | [versioning/spec.md](openspec/specs/versioning/spec.md) | [bump-version.sh](scripts/bump-version.sh#L16), [handlers.rs](src-tauri/src/handlers.rs#L55) |
