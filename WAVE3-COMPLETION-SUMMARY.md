# Wave 3 Completion Summary — Observability Chain Specification Updates

## Overview

Wave 3 successfully updated the OpenSpec specifications to document the observability-chain fixes that enable deterministic exit codes and safe command chaining. All three critical CLI entry points now explicitly specify their exit code contracts, and a comprehensive end-to-end test case documents the expected behavior.

## Completed Tasks

### Task 1: Update openspec/specs/init-command/spec.md ✓

Added four new requirements to document the `--init` command's observability contracts:

**New Sections:**
- **Exit code contract**: 0 = all images built successfully, 1 = any image failed
- **Debug mode log capture**: Each build teed to `/tmp/tillandsias-init-{image}.log`, failed logs displayed inline
- **All images built**: Documents six images in sequence (proxy, forge, git, inference, chromium-core, chromium-framework)
- **Sources of Truth**: References to `build-lock-semantics.md` and `container-image-tagging.md` cheatsheets

**Key Insight:** Exit codes enable safe chaining — `./build.sh --install && tillandsias --init --debug && tillandsias /path --diagnostics`

**File:** `/var/home/machiyotl/src/tillandsias/openspec/specs/init-command/spec.md`

**Commit:** `50a6398` — "spec(init-command): document exit codes and --debug behavior"

---

### Task 2: Create openspec/specs/cli-diagnostics/spec.md (Promotion from Delta) ✓

Created main-tree spec promoting the delta spec from the end-to-end-diagnostics-cli change.

**New Spec File:** `/var/home/machiyotl/src/tillandsias/openspec/specs/cli-diagnostics/spec.md`

**New Requirements:**
- **Exit code contract (CORRECTED)**: 
  - Exit 0 when containers exist and logs streaming
  - Exit 1 when no containers found for project
  - Fixes Bug 3: enables safe chaining (`tillandsias /path --diagnostics && echo "ready"`)

- **Container source labels**: Consistent format `[type:project]` for filtering and scanning
- **Debug mode verbose output**: Lists discovered containers with startup params
- **Error handling**: Graceful exits if container stopped during streaming

**Traceability:**
- Annotated in `/var/home/machiyotl/src/tillandsias/src-tauri/src/handlers.rs#L4462`
- Annotated in `/var/home/machiyotl/src/tillandsias/src-tauri/src/main.rs#L133`

**File:** `/var/home/machiyotl/src/tillandsias/openspec/specs/cli-diagnostics/spec.md`
**TRACES:** `/var/home/machiyotl/src/tillandsias/openspec/specs/cli-diagnostics/TRACES.md`

**Commit:** `09e2370` — "spec(cli-diagnostics): promote from delta, document exit codes and container discovery"

---

### Task 3: Update openspec/specs/dev-build/spec.md ✓

Added exit code contract for `./build.sh --install`:

**New Requirement:** Install exits with deterministic exit codes
- **Exit 0**: Binary installed, critical images built
- **Exit 1**: Build failed (image build or binary copy failure)
- Enables chaining: `./build.sh --install && tillandsias --init --debug && tillandsias /path --diagnostics`

**File:** `/var/home/machiyotl/src/tillandsias/openspec/specs/dev-build/spec.md`

**Commit:** `8886356` — "spec(dev-build): document install exit code contract"

---

### Task 4: Verify @trace Annotations in handlers.rs ✓

Confirmed existing `@trace` annotations:

**In handlers.rs (line 4462):**
```rust
/// @trace spec:cli-diagnostics, spec:observability-convergence
pub async fn handle_diagnostics(project_path: Option<&std::path::Path>, debug: bool) -> Result<(), String> {
```

**In main.rs (line 133):**
```rust
// Diagnostics mode — stream container logs and exit.
// @trace spec:cli-diagnostics
if let cli::CliMode::Diagnostics { path, debug } = cli_mode {
```

**Status:** Already properly annotated from Bug 3 fix. No changes needed.

---

### Task 5: End-to-End Test Case Documentation ✓

Created comprehensive e2e test specification documenting the full observability chain.

**File:** `/var/home/machiyotl/src/tillandsias/openspec/WAVE3-E2E-VERIFICATION.md`

**Test Case Structure:**

1. **Phase 1: Binary Build**
   - Spec: `dev-build`
   - Command: `./build.sh --install`
   - Exit code: 0
   - Verification: Binary on PATH

2. **Phase 2: Image Pre-Build**
   - Spec: `init-command`
   - Command: `tillandsias --init --debug`
   - Exit code: 0 (success), 1 (failure)
   - Verification: 6 images built/cached, logs at `/tmp/tillandsias-init-*.log`

3. **Phase 3: Diagnostics with Containers**
   - Spec: `cli-diagnostics`
   - Command: `tillandsias /tmp/test-project --diagnostics --debug`
   - Exit code: 0 (containers running), 1 (no containers)
   - Verification: `[diagnostics] SUCCESS: monitoring N containers`, logs streamed

4. **Phase 4: Chaining End-to-End**
   - Command: `./build.sh --install && tillandsias --init --debug && tillandsias /path --diagnostics`
   - Verifies exit codes compose correctly in shell pipelines

**Commit:** `b305d86` — "docs(e2e): add Wave 3 end-to-end verification test case"

---

## Observability Chain Convergence

The three specs now form a complete, documented chain:

```
./build.sh --install
    ↓ (exit 0/1 on success/failure)
    ├─> [build] SUCCESS/ERROR
    
tillandsias --init --debug
    ↓ (exit 0/1)
    ├─> 6 images built: proxy, forge, git, inference, chromium-core/framework
    ├─> /tmp/tillandsias-init-{image}.log (debug mode)
    └─> Failed logs displayed inline

tillandsias /path --diagnostics
    ↓ (exit 0/1)
    ├─> SUCCESS: monitoring N containers
    ├─> [type:project] live logs
    └─> ERROR: no containers found (exit 1)
```

**Key Achievement:** All three commands exit deterministically, enabling safe chaining:
- `command1 && command2 && command3` (all succeed)
- `command1 || echo "failed"` (error handling)
- Compose in arbitrary pipeline scripts

---

## File Locations

### Specs Updated/Created
- `/var/home/machiyotl/src/tillandsias/openspec/specs/init-command/spec.md` (updated)
- `/var/home/machiyotl/src/tillandsias/openspec/specs/cli-diagnostics/spec.md` (new)
- `/var/home/machiyotl/src/tillandsias/openspec/specs/cli-diagnostics/TRACES.md` (new)
- `/var/home/machiyotl/src/tillandsias/openspec/specs/dev-build/spec.md` (updated)

### Documentation
- `/var/home/machiyotl/src/tillandsias/openspec/WAVE3-E2E-VERIFICATION.md` (new)

### Code (already annotated)
- `/var/home/machiyotl/src/tillandsias/src-tauri/src/handlers.rs#L4462` (@trace spec:cli-diagnostics)
- `/var/home/machiyotl/src/tillandsias/src-tauri/src/main.rs#L133` (@trace spec:cli-diagnostics)

---

## Commit History

```
b305d86 docs(e2e): add Wave 3 end-to-end verification test case
8886356 spec(dev-build): document install exit code contract
09e2370 spec(cli-diagnostics): promote from delta, document exit codes and container discovery
50a6398 spec(init-command): document exit codes and --debug behavior
```

All commits include:
- Proper commit messages with @trace annotations
- GitHub search URLs for specification traceability
- Co-authored-by Claude Haiku 4.5 footer

---

## Next Steps (Optional)

Future work to consider:
1. Run the WAVE3-E2E-VERIFICATION test case on Linux to validate behavior
2. Add cheatsheets referenced in "Sources of Truth" sections (if missing)
3. Generate/update TRACES files with absolute paths to annotated code locations
4. Consider promoting delta specs from the `end-to-end-diagnostics-cli` change if not already done

---

## Metadata

- **Wave:** 3 (OpenSpec specs)
- **Date Completed:** 2026-05-02
- **Status:** Complete
- **Commits:** 4 (all merged to main)
- **Spec Files:** 4 (2 updated, 2 new)
- **Documentation:** 1 (e2e test case)
