## Context

The current `cli.rs` defines a static `USAGE` string with 10 lines of help text. The `parse()` function handles `--help` by printing this string and returning `None`. There is no welcome banner -- the CLI goes straight to container launch or tray mode.

The application version is available as `env!("CARGO_PKG_VERSION")` (3-part semver, e.g., `0.1.97`) and from the `VERSION` file at project root (4-part, e.g., `0.1.97.76`). The host OS is detected by `tillandsias_core::config::detect_host_os()`. Podman availability is checked by `PodmanClient::is_available()`. Forge image status is checked by `PodmanClient::image_exists()`.

## Goals / Non-Goals

**Goals:**
- Welcome banner shows version, OS, podman status, and forge readiness at a glance
- Help text is sectioned by purpose: accountability, options, maintenance
- Banner is suppressed when output is not a terminal (piped, redirected, tray mode)
- Banner does not delay container launch (all checks are fast, < 100ms)
- Help text includes the new `--log` and `--log-*` flags (even before they are implemented, as a preview)

**Non-Goals:**
- Color/emoji in help output (follow existing convention -- no emoji in code unless user asks)
- Interactive help or man pages
- Shell completions (future enhancement)
- Changing the banner for tray mode (no terminal = no banner)

## Decisions

### D1: Welcome banner format

**Choice:**

```
Tillandsias v0.1.97.76
  OS: Fedora Silverblue 43
  Podman: 5.8.1
  Forge: tillandsias-forge:v0.1.97 (ready)

  Try: tillandsias --help
```

Variants for different states:

```
Tillandsias v0.1.97.76
  OS: Fedora Silverblue 43
  Podman: not found

  Install podman to use Tillandsias.
```

```
Tillandsias v0.1.97.76
  OS: Fedora Silverblue 43
  Podman: 5.8.1
  Forge: building... (first run)

  Try: tillandsias --help
```

**Why:** Brief, scannable, answers the three questions a user has when launching: "What version am I running?", "Is my system ready?", "What can I do?". The 4-part version is shown because that is the version reported in issues and the accountability window. The "Try: --help" line is omitted when the user is already in attach mode (they know what they're doing).

### D2: Banner only in CLI attach mode, only on TTY

**Choice:** The welcome banner prints ONLY when:
1. Running in CLI attach mode (`tillandsias <path>`)
2. stdout is a terminal (`std::io::stdout().is_terminal()`)

It does NOT print in:
- Tray mode (no terminal)
- Piped output (`tillandsias . | grep something`)
- The `--help`, `--stats`, `--clean`, `--update`, `init` subcommands (they print their own output)

**Why:** The banner is informational context for interactive use. It would be noise in scripted/automated contexts.

### D3: Sectioned help text

**Choice:**

```
Tillandsias — development environment manager

USAGE:
  tillandsias                        Start the system tray app
  tillandsias <path>                 Attach a dev environment to a project
  tillandsias init                   Pre-build environment images

ACCOUNTABILITY:
  --log-secret-management            Show how secrets are handled (no secrets shown)
  --log-image-management             Show environment image lifecycle
  --log-update-cycle                 Show update check and apply flow

OPTIONS:
  --log=MODULES                      Per-module log levels
                                     (e.g., secrets:trace;events:debug)
  --image <name>                     Environment image to use (default: forge)
  --debug                            Show verbose output including commands
  --bash                             Drop into fish shell for troubleshooting

MAINTENANCE:
  --stats                            Show disk usage from Tillandsias artifacts
  --clean                            Remove stale artifacts and reclaim disk space
  --update                           Check for updates and apply if available

  --help                             Show this help
  --version                          Show version information
```

**Why:** Grouping by purpose helps users find what they need. The "ACCOUNTABILITY" section is prominently placed because transparency is a core project value. The section ordering (Usage > Accountability > Options > Maintenance) reflects frequency of use.

**Implementation note:** User-facing text MUST NOT contain "container", "pod", "image" (per CLAUDE.md). The current help text already says "Container image" which should be changed to "Environment image" or just "image". All references are to "environment" or "project".

### D4: `--version` flag

**Choice:** Add `--version` flag that prints the 4-part version and exits:

```
tillandsias 0.1.97.76
```

**Why:** Standard CLI convention. The version is the same one shown in the welcome banner, commit tags, and accountability output. Read from the `VERSION` file at build time (embedded via `include_str!` or equivalent).

### D5: Podman version detection for banner

**Choice:** Run `podman --version` and parse the output to extract the version string. This is a synchronous check in the CLI path (before async runtime starts).

**Why:** The banner needs podman version before launching the container. The check is fast (< 50ms). If podman is not found, the banner shows "not found" and the subsequent container launch will fail with a clear error.

**Implementation:**
```rust
fn detect_podman_version() -> Option<String> {
    let output = std::process::Command::new("podman")
        .arg("--version")
        .output()
        .ok()?;
    // "podman version 5.8.1" -> "5.8.1"
    let stdout = String::from_utf8_lossy(&output.stdout);
    stdout.trim().strip_prefix("podman version ")
        .map(|v| v.to_string())
}
```

### D6: Forge image status for banner

**Choice:** Check if the current version's forge image exists: `podman image exists tillandsias-forge:v<version>`.

Display states:
- Image exists: `Forge: tillandsias-forge:v0.1.97 (ready)`
- Image absent, older version exists: `Forge: update needed (current: v0.1.95)`
- No image at all: `Forge: not built (run: tillandsias init)`
- Podman not available: line omitted

**Why:** Users need to know if their environment is ready before attaching. The status guides them to the right action.

## Open Questions

1. **Should the banner show GPU status?** Currently `detect_gpu_devices()` runs during tray setup. For CLI mode, showing "GPU: NVIDIA RTX 4070 (passthrough ready)" could be useful for AI-heavy workloads. **Leaning toward: no, keep the banner minimal. GPU info belongs in `--debug` output.**

2. **Should `--version` show the full banner or just the version number?** `--version` is conventionally just the version for script consumption. The banner provides the rich info. **Decision: `--version` prints just `tillandsias 0.1.97.76`, banner is separate.**
