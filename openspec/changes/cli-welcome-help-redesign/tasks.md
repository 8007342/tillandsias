## Phase 1: Sectioned Help Text

- [ ] 1.1 Replace the static `USAGE` string in `cli.rs` with a sectioned format containing USAGE, ACCOUNTABILITY, OPTIONS, MAINTENANCE sections. Include placeholder entries for `--log=MODULES`, `--log-secret-management`, `--log-image-management`, `--log-update-cycle` flags (marked as "coming soon" or just present — they parse but are no-ops until the logging change lands).
- [ ] 1.2 Audit all user-facing text in the help output for forbidden words: "container", "pod", "image" (container), "runtime" (container). Replace with "environment", "project", etc. per CLAUDE.md conventions. Note: "image" in the context of `--image <name>` should become `--env <name>` or similar.
- [ ] 1.3 Add `--version` flag handling to `cli::parse()`. Print `tillandsias <4-part-version>` and return `None`. The 4-part version is embedded at build time via `include_str!("../../VERSION")` trimmed.
- [ ] 1.4 Add unit tests for help text: verify `--help` output contains all section headers, verify `--version` outputs the version string.

## Phase 2: Welcome Banner

- [ ] 2.1 Create `fn print_welcome_banner()` in `cli.rs` (or a new `banner.rs` module). The function:
    - Checks `std::io::stdout().is_terminal()` — exits early if not a TTY
    - Reads the 4-part version from the embedded VERSION string
    - Calls `detect_host_os()` for the OS line
    - Calls `detect_podman_version()` for the Podman line
    - Calls `check_forge_image_status()` for the Forge line
    - Prints the formatted banner to stdout
- [ ] 2.2 Implement `detect_podman_version() -> Option<String>` — runs `podman --version` synchronously, parses `"podman version X.Y.Z"` to extract `"X.Y.Z"`.
- [ ] 2.3 Implement `check_forge_image_status() -> ForgeStatus` enum with variants: `Ready(tag)`, `UpdateNeeded(current_tag, expected_tag)`, `NotBuilt`, `PodmanUnavailable`. Uses synchronous `podman image exists` check.
- [ ] 2.4 Call `print_welcome_banner()` in `runner.rs` before the container launch sequence (after CLI parse, before podman run). Only in attach mode.
- [ ] 2.5 Suppress banner when `--debug` is active (debug output replaces the banner with more detailed info).
- [ ] 2.6 Add unit test for `detect_podman_version()` parsing: standard format, unexpected format, missing binary.
- [ ] 2.7 Manual test: run `tillandsias <project>` from a terminal, verify banner appears. Run `tillandsias <project> | cat`, verify banner does NOT appear (not a TTY). Run `tillandsias --help`, verify banner does NOT appear (help mode).

## Phase 3: Refinement

- [ ] 3.1 When `logging-accountability-framework` lands, update the help text to remove any "coming soon" markers from the `--log-*` flags.
- [ ] 3.2 When `secret-rotation-tokens` lands, update the banner to show token delivery mechanism status (tmpfs vs hosts.yml fallback) in `--debug` mode.
- [ ] 3.3 Consider adding `--quiet` flag to suppress the banner for scripted usage (alternative to piping). Low priority — piping already suppresses it.
