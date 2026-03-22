## Context

Tillandsias is a Tauri v2 desktop application (Rust + system tray) targeting Linux, macOS, and Windows. The project uses a Rust workspace with `src-tauri/` as the Tauri build context. Tauri's CLI (`tauri build`) produces platform-native bundles: AppImage on Linux, .app/.dmg on macOS, and .exe/.msi on Windows. The release strategy (TILLANDSIAS-RELEASE.md) specifies GitHub Releases as the distribution platform, semantic versioning with `v*` tags, and SHA256 checksums as the Phase 1 integrity mechanism.

**Constraints:**
- Free tier GitHub Actions must be sufficient
- No secrets or signing keys in Phase 1 (Cosign comes in Phase 2)
- Artifacts must follow a predictable naming convention for scripted downloads and the auto-updater (Phase 3)
- All CI dependencies must be hash-pinned to mitigate supply chain attacks

## Goals / Non-Goals

**Goals:**
- Automated multi-platform builds triggered by version tags
- Consistent artifact naming for all platforms
- SHA256 checksum file covering all release artifacts
- Draft release creation with artifacts uploaded, published after verification
- Reproducible build environment via pinned dependencies

**Non-Goals:**
- Binary signing (Phase 2: cosign-signing)
- Auto-update endpoint or metadata (Phase 3: auto-updater)
- macOS notarization or Windows code signing (Phase 4)
- Reproducible builds via Nix (Phase 5)
- Building on every push or PR (this workflow is release-only)

## Decisions

### D1: GitHub Actions Matrix Strategy

**Choice:** Single workflow file with a matrix strategy covering three platform targets.

```yaml
strategy:
  matrix:
    include:
      - target: x86_64-unknown-linux-gnu
        os: ubuntu-latest
        artifact: tillandsias-*.AppImage
      - target: aarch64-apple-darwin
        os: macos-latest
        artifact: tillandsias-*.dmg
      - target: x86_64-pc-windows-msvc
        os: windows-latest
        artifact: tillandsias-*.exe
```

**Why over separate workflows per platform:** A single matrix workflow is easier to maintain, ensures all platforms build from the same tag, and produces a unified set of artifacts for the release step. The matrix approach also makes it trivial to add targets later (e.g., `x86_64-apple-darwin`, `aarch64-unknown-linux-gnu`).

**Alternatives considered:**
- Separate workflow files per OS -- duplicates trigger logic, versioning, and release creation. Coordination overhead.
- Reusable workflow with platform-specific callers -- adds indirection without meaningful benefit at three targets.

### D2: Tag-Triggered Release Flow

**Choice:** Workflow triggers on `push.tags: ['v*']` only. The flow is:

1. Tag push triggers the workflow
2. Matrix builds run in parallel
3. A final job (needs all build jobs) creates a GitHub Release as draft
4. Artifacts and checksums are uploaded to the draft release
5. The release is published automatically

**Why draft-then-publish:** Gives maintainers a window to inspect artifacts before public release. The auto-publish can be toggled to manual if needed.

**Version extraction:** The version is extracted from the tag (`github.ref_name`) and validated against `Cargo.toml` workspace version to prevent mismatches.

### D3: Artifact Naming Convention

**Choice:** `tillandsias-{version}-{os}-{arch}.{ext}`

Examples:
- `tillandsias-v0.1.0-linux-x86_64.AppImage`
- `tillandsias-v0.1.0-macos-aarch64.dmg`
- `tillandsias-v0.1.0-windows-x86_64.exe`

**Why include arch in the name:** Future-proofs for multi-arch builds (Intel Mac, ARM Linux) without renaming existing artifacts.

**Renaming from Tauri defaults:** Tauri produces artifacts with its own naming scheme. A post-build step renames artifacts to match the convention. This decouples our distribution naming from Tauri internals.

### D4: SHA256 Checksum Generation

**Choice:** A dedicated checksum job (runs after all builds) downloads all artifacts and produces a single `SHA256SUMS` file using `sha256sum`.

```
e3b0c44298fc1c149afbf4c8996fb924...  tillandsias-v0.1.0-linux-x86_64.AppImage
a7ffc6f8bf1ed76651c14756a061d662...  tillandsias-v0.1.0-macos-aarch64.dmg
cf83e1357eefb8bdf1542850d66d8007...  tillandsias-v0.1.0-windows-x86_64.exe
```

**Why a separate job:** Checksums must cover ALL artifacts. Running in the build matrix would only checksum one artifact per job. A fan-in job after all builds ensures completeness.

**Verification by users:**
```bash
sha256sum -c SHA256SUMS
```

### D5: Dependency Pinning

**Choice:** All GitHub Actions are pinned by full commit SHA, not version tag.

```yaml
- uses: actions/checkout@<full-sha>  # v4.1.0
```

**Why over version tags:** Version tags are mutable references. An attacker who compromises an action repository can move a tag to point to malicious code. SHA pinning is immutable and verifiable. Comment annotations track the human-readable version for maintainability.

**Automated updates:** Dependabot or Renovate can propose SHA updates via PR, keeping pins current without manual tracking.

### D6: Tauri Build Dependencies

**Choice:** Each matrix runner installs platform-specific Tauri build dependencies before building.

| Platform | Dependencies |
|----------|-------------|
| Linux | `libwebkit2gtk-4.1-dev`, `libappindicator3-dev`, `librsvg2-dev`, `patchelf` |
| macOS | Xcode command line tools (pre-installed on `macos-latest`) |
| Windows | WebView2 (pre-installed on `windows-latest`), MSVC toolchain |

**Rust toolchain:** Installed via `dtolnay/rust-toolchain` action pinned by SHA, targeting `stable` channel with the appropriate target triple.

## Risks / Trade-offs

**[macOS runner architecture]** GitHub's `macos-latest` runners are now Apple Silicon (M1+). This builds `aarch64-apple-darwin` natively. If Intel Mac support is needed, a separate `macos-13` runner (Intel) must be added to the matrix. Deferred until demand exists.

**[Windows artifact size]** Windows .exe bundles are typically larger due to WebView2 bootstrapper. No mitigation needed for MVP; users expect larger Windows downloads.

**[Runner availability]** GitHub Actions free tier has limited macOS and Windows minutes. Tillandsias's release cadence (weekly at most) stays well within limits. If build times grow, caching Rust compilation (`Swatinem/rust-cache`) reduces build minutes.

**[Tauri artifact naming changes]** Tauri may change its output naming across versions. The rename step absorbs this, but must be updated when Tauri is upgraded.

## Resolved Questions

- **AppImage vs Flatpak vs .deb:** AppImage chosen per TILLANDSIAS-RELEASE.md -- portable, zero-install, single file. Flatpak/deb are future distribution channels.
- **Draft vs immediate release:** Draft chosen for inspection window. Can be changed to immediate publish later.

## Open Questions

- **ARM Linux builds:** Should `aarch64-unknown-linux-gnu` be included in the initial matrix? ARM Linux runners are available but add build time. Defer until demand.
- **Build caching strategy:** How aggressively should Rust compilation artifacts be cached between releases? Stale caches can cause subtle issues; fresh builds are more reliable but slower.
