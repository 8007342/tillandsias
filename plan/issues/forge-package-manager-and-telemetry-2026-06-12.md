# Forge Package Manager Migration and Build Telemetry

**Context:**
The current `images/default/Containerfile` installs multiple dependencies via explicit `curl` and `tar`/`gz` manipulations (e.g., `cargo-binstall`, `cargo-nextest`, `actionlint`, `vale`, `dart-sdk`). To streamline the build and reduce fragility, we need to migrate these to native `dnf` / `microdnf` installs where Fedora Minimal provides appropriate packages.

**Requirements:**
1. Migrate `curl` installers in `images/default/Containerfile` to `dnf` (`microdnf`).
   - For tools missing from Fedora Minimal (e.g., flutter), it is acceptable to add their official "respectable" repositories.
   - Maintain a "forge dependency list" of all foreign repos added. This list must be exposed in the `tellme` system for complete transparency.
2. Add telemetry to the image build process (`build.sh`, `build-forge.sh`) to record:
   - Install duration per component.
   - Download sizes.
   - Output as a tail of JSON lines, employing semantic distillation (logarithmic historic trails) to age out old data.
   - Create a Markdown dashboard file containing **Mermaid graphs** to track size and speed improvements over time. Mermaid is required so the graphs render natively and effortlessly when viewed on GitHub, without requiring local JS servers.
3. Save forge build output directly in the development environment for analysis. This allows agents to review the warnings and errors generated during the image build process and iterate upon them.
4. Support the `/forge-continuous-enhancement` skill.
5. **Image Architecture Refactoring**:
   - Split `images/default/Containerfile` into `Containerfile.base` (contains all heavy DNF installs) and `Containerfile` (which `FROM`s the base and bakes in skills, config, and entrypoints).
   - This ensures rapid rebuilds during development iteration while still producing a hard-baked container with skills included for user runtime.
