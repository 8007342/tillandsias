## Capability: ux-strings

User-facing string consistency and correctness across the Tillandsias tray app, CLI commands, and shell scripts.

## Requirements

### R1: Build chip labels MUST NOT contain duplicated words

The tray menu build progress chip labels must produce grammatically correct English:
- InProgress (standard): `"⏳ Building {image_name}..."`
- InProgress (Maintenance): `"⛏️ Setting up Maintenance..."`
- Completed: `"✅ {image_name} ready"`
- Failed: `"❌ {image_name} build failed"`

The `image_name` passed to `build_chip_label()` MUST NOT itself contain the word "Building". Image names should be bare nouns: `"Forge"`, `"Updated Forge"`, `"Maintenance"`.

### R2: CLI checkmark style is uniform within each output context

| Context | Success | Failure | Waiting |
|---------|---------|---------|---------|
| CLI stdout | `\u{2713}` (✓) | `\u{2717}` (✗) | `\u{231B}` (⌛) |
| Tray menu | `\u{2705}` (✅) | `\u{274C}` (❌) | `\u{23F3}` (⏳) |
| Shell scripts | literal `✓` | literal `✗` | (n/a) |

Within a single file, the same character MUST be represented the same way (either Unicode escape or literal, not mixed).

### R3: Repeated error messages are defined once

Error messages that appear in more than 2 locations MUST be defined as named constants and referenced by name. At minimum:

- `SETUP_ERROR` — the "Tillandsias is setting up. If this persists..." message
- `ENV_NOT_READY` — the "Development environment not ready yet..." message
- `INSTALL_INCOMPLETE` — the "Tillandsias installation may be incomplete..." message

### R4: CLI output alignment is correct

Labels in tabular CLI output (e.g., `--stats`) must have consistent padding between the label and the value. No missing spaces between colons and values.

### R5: Implementation details are not shown to end users

Internal URLs (update endpoint), hash values, and debug information MUST NOT appear in non-debug output. The `--debug` flag gates verbose/internal output.

## Verification

- `cargo test --workspace` passes
- Visual inspection of each CLI command's output for alignment and consistency
- Trigger a forge build and verify tray menu chip label reads "Building Forge..." (not "Building Building Forge...")
