## Context

The Tillandsias binary is signed (Tauri Ed25519 + Cosign). But it executes unsigned shell scripts from `~/.local/share/tillandsias/` — breaking the chain of trust. An attacker with write access to the user's home directory can modify these scripts to steal credentials, inject malicious code into containers, or compromise the image build pipeline.

The forge container image sources (entrypoint, configs, flake) face the same risk: if tampered on disk, the next image rebuild bakes the malicious content into a trusted image.

## Goals / Non-Goals

**Goals:**
- Embed all executable content in the signed binary
- Write to temp only when needed, delete after use
- Maintain the same functionality (gh auth, image build, image sources)
- Keep `build.sh --install` minimal (binary + icons only)

**Non-Goals:**
- Embedding the forge container image itself (it's built from sources, verified by Nix)
- Protecting against root-level attackers (they can modify the binary too)
- Encrypting embedded content (it's open source, obfuscation is pointless)

## Decisions

### Decision 1: `include_str!` / `include_bytes!` for embedding

**Choice**: Use Rust's compile-time inclusion macros. Each script becomes a `const &str` in an `embedded.rs` module.

**Files to embed**:
| File | Macro | Usage |
|------|-------|-------|
| `gh-auth-login.sh` | `include_str!` | Written to temp, executed via `open_terminal()` |
| `scripts/build-image.sh` | `include_str!` | Written to temp, executed for image builds |
| `scripts/ensure-builder.sh` | `include_str!` | Written to temp, called by build-image.sh |
| `flake.nix` | `include_str!` | Written to temp for `nix build` |
| `flake.lock` | `include_str!` | Written to temp for `nix build` |
| `images/default/entrypoint.sh` | `include_str!` | Written to temp for image build |
| `images/default/shell/*` | `include_str!` | Written to temp for image build |
| `images/default/skills/**` | `include_str!` | Written to temp for image build |

**Rationale**: Zero dependencies, compile-time verified, content is part of the signed binary. `include_str!` paths are relative to the source file, resolved at compile time.

### Decision 2: Temp directory for runtime extraction

**Choice**: Write embedded scripts to `$XDG_RUNTIME_DIR/tillandsias/` (Linux) or equivalent temp dir. This is RAM-backed, per-session, auto-cleaned on logout. Set the files to mode 0700 (owner-only executable). Delete after use when possible.

**For image builds**: The entire `images/` tree and flake files need to exist on disk for `nix build` to reference them. Write to a temp dir, run the build, then clean up.

**For gh-auth-login**: Write the script, pass it to `open_terminal()`, the script self-deletes or temp is cleaned on logout.

### Decision 3: Helper function pattern

**Choice**: `embedded::write_temp_script(name, content) -> PathBuf` — writes content to the runtime temp dir, sets executable permission, returns the path. Caller is responsible for cleanup (or relies on session temp cleanup).

For the image build tree: `embedded::write_image_sources() -> TempDir` — writes the full directory structure to a `tempfile::TempDir` which auto-deletes on drop.

## Risks / Trade-offs

- **[Binary size increase]** → Shell scripts and configs are small (< 50KB total). Negligible impact.
- **[Race condition on temp files]** → Mitigated by writing to per-user runtime dir with 0700 permissions. The window between write and execute is milliseconds.
- **[Dev workflow]** → During development, the binary embeds the source-tree versions of scripts. Changes to scripts require a rebuild. This is intentional — it matches the release flow.
