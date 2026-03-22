## Context

The tray app uses Tauri for system tray menus and async event loops. CLI mode needs none of that. When the user passes a path argument, the binary should skip Tauri entirely, build/check the image, print user-friendly status, and exec `podman run -it --rm` with inherited stdio so the terminal passes through to the container.

## Goals / Non-Goals

**Goals:**
- `tillandsias <path>` launches an interactive container with pretty terminal output
- `tillandsias` (no args) starts the tray app as before
- `--image <name>` flag to select image (default: "forge")
- `--debug` flag for verbose output
- `--help` prints usage
- Clean exit message when container stops

**Non-Goals:**
- Full CLI framework (clap, etc.) — manual arg parsing keeps dependencies minimal
- Background/detached containers from CLI (that's what the tray app does)
- Multiple simultaneous CLI containers (one at a time, foreground)

## Decisions

### D1: Manual arg parsing (no clap dependency)

The CLI surface is tiny: one positional arg, two flags. Adding clap would increase compile time and binary size for minimal benefit. A simple `std::env::args()` loop handles this cleanly.

### D2: println! output, not tracing

CLI output uses `println!` with formatted messages for the user. Tracing is still initialized for file logging (useful for debugging), but the terminal shows clean human-readable progress like "Checking image... tillandsias-forge:latest" instead of structured log lines.

### D3: podman run with inherited stdio

The runner calls `std::process::Command::new("podman").arg("run").args(&run_args).status()` (not `.spawn()` or `.output()`). Using `.status()` inherits stdin/stdout/stderr so the container's terminal passes through directly. The process blocks until the container exits.

### D4: Image name mapping

The `--image` flag takes a short name ("forge", "web") and maps it to the full image tag (`tillandsias-forge:latest`, `tillandsias-web:latest`). Default is "forge". Unknown names are used as-is (allows custom images).

### D5: Container naming

CLI containers use the same naming convention as tray: `tillandsias-<project>-<genus>`. The genus is always Aeranthos for CLI mode (no allocator needed for single foreground container).

### D6: Security flags are identical

CLI mode uses the exact same security flags as the tray mode: `--cap-drop=ALL`, `--security-opt=no-new-privileges`, `--userns=keep-id`, `--security-opt=label=disable`. These are non-negotiable.
