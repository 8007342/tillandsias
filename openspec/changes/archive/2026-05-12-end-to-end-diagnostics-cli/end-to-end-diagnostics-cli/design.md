# end-to-end-diagnostics-cli Design

## Context

Tillandsias uses multi-container enclaves (proxy, forge, git, inference) plus new browser isolation containers (browser-core, browser-framework). Currently:
- `tillandsias --init` builds proxy, forge, git, inference but NOT browser containers
- No diagnostic/troubleshooting mode exists to inspect container logs
- Observable traceability (spec → code) exists but not observability (runtime → spec)

Users cannot easily verify initialization success or debug container failures. We need a cohesive initialization + diagnostics workflow.

## Goals / Non-Goals

**Goals:**
- `tillandsias --init --debug` builds all 6 container images (proxy, forge, git, inference, browser-core, browser-framework) with verbose logging
- `tillandsias --diagnostics` aggregates live `podman logs -f` from all running Tillandsias containers, labeled by source, to terminal
- Observable convergence: `@trace spec:<name>` annotations in code, events logged with `spec=` + `cheatsheet=` attributes
- All container/logging behavior documented in cheatsheets with provenance (version, last-updated, source URLs)
- Delta specs for modified `init-command` with new requirements reflected
- Zero additional dependencies (uses existing podman, logging infrastructure)

**Non-Goals:**
- Persistent log storage or rotation (diagnostics is read-only, real-time)
- Log filtering by level/source (show all; user can pipe `| grep`)
- Integration with external monitoring systems
- Changes to container naming, lifecycle, or enclave architecture
- Browser container execution during --init (we only build, don't run)

## Decisions

### 1. **CLI flag parsing: `--diagnostics` is project-path-based, not a standalone mode**

**Decision**: `tillandsias --diagnostics <project-path>` tails logs from containers running for that project (and shared infra like proxy).

**Rationale**:
- Diagnostics is most useful when debugging a specific project's OpenCode Web + browser containers
- Avoids ambiguity: what logs to show if no project context?
- Follows existing pattern: `tillandsias <project-path>` launches OpenCode, `tillandsias --diagnostics <project-path>` inspects its logs

**Alternatives considered**:
- Global `--diagnostics` (no project path): ambiguous which containers to tail
- `tillandsias --tail-logs` as a daemon mode: too heavyweight; users want quick inspection
- Separate binary `tillandsias-logs`: breaks CLI cohesion

### 2. **Log aggregation: subprocess tail with interleaved output + source labels**

**Decision**: Spawn `podman logs -f` for each container in parallel, prefix each line with `[container_name]`, redirect all to stderr (user terminal sees output even if stdout is captured).

**Rationale**:
- Simple: no log buffering or custom aggregation logic
- Real-time: podman streams directly to terminal as events happen
- Labeled: users know which container each log line comes from
- Interruptible: Ctrl+C kills all podman log processes gracefully

**Alternatives considered**:
- Use podman's event API to reconstruct logs: complex, not real-time, requires polling
- Write custom log aggregator in Rust: adds complexity, duplicates podman's work
- Single `podman logs -f <container1> <container2> ...`: podman doesn't support multi-container tail

### 3. **Init enhancements: reuse existing `build_image()` function for browser containers**

**Decision**: Add browser-core and browser-framework to the image list in `init.rs::run()`. Use same staleness detection, lock mechanism, old image pruning.

**Rationale**:
- No new build infrastructure; browser images built same way as proxy/forge
- Staleness detection already avoids rebuilding unchanged images
- Existing lock prevents concurrent builds from different tray instances
- `--debug` flag already exists in other handlers; extend to skip timeouts in init

**Alternatives considered**:
- Separate browser build flow: duplicates lock/staleness/pruning logic
- Skip browser builds in init, always build on first browser launch: defeats the purpose of `--init`
- Conditional build (--browser flag): complicates CLI; all-or-nothing simpler

### 4. **Observability: event attributes (spec=, cheatsheet=) + @trace annotations**

**Decision**: 
- `@trace spec:<name>` near every code block implementing a spec requirement
- Log events emit with `spec = "name"` + `cheatsheet = "path/to.md"` fields
- Cheatsheets include `## Provenance` section: vendor URL + last-updated date

**Rationale**:
- Bidirectional traceability: code ↔ spec (via @trace), code ↔ cheatsheet (via event attributes)
- Convergence is observable: spec → code (annotations) and code → spec (logs link back)
- Provenance pins versions; tool changes invalidate cheatsheets, visible in log diffs
- Fulfills "observable convergence" requirement: users grep logs for `spec=cli-diagnostics` and jump to implementation

**Alternatives considered**:
- Comments alone: not queryable at runtime
- Structured logs only (no @trace): code changes become invisible without runtime
- No cheatsheet provenance: tool version drift silent until production failure

### 5. **Cheatsheet scope: two new cheatsheets (podman-logging, container-lifecycle)**

**Decision**:
- `docs/cheatsheets/podman-logging.md`: `podman logs` options, `podman events`, filtering patterns, timestamps. Provenance: Red Hat podman docs, last-updated date.
- `docs/cheatsheets/container-lifecycle.md`: state machine (created, started, running, stopped, removed), status checks, cleanup commands. Provenance: OCI container spec, last-updated date.

**Rationale**:
- Separates operational knowledge from implementation code
- Referenced in specs via `## Sources of Truth` section (new CLAUDE.md convention)
- Cheatsheet staleness is visible: if podman version changes, cheatsheet version pin is now wrong
- Users can `cat $TILLANDSIAS_CHEATSHEETS/podman-logging.md` inside forge for same knowledge

**Alternatives considered**:
- Inline comments in code: not easily accessible; scattered
- Single monolithic cheatsheet: mixes concerns; harder to version independently
- No cheatsheets: loses the source-of-truth anchor for tool versions

## Risks / Trade-offs

| Risk | Mitigation |
|------|-----------|
| **Browser images don't exist yet** → build fails in `--init` | Create browser-core/framework Containerfiles before implementation; ref TRACES show where they're defined |
| **Podman log output ordering is not ordered per-event** → timestamps from different containers interleave | Prefix each line with `[container]` + microsecond timestamp so users can correlate; mention in cheatsheet |
| **User expects log filtering (by level, source, keyword)** → diagnostics shows everything | Document in CLI help: "Use `\| grep` to filter"; add to cheatsheet as pattern |
| **Cheatsheets become stale when podman ships breaking changes** → provenance pins version but doesn't auto-update | Add pre-commit hook to warn if cheatsheet `Last updated` > 90 days old; separate follow-up task |
| **`--init --debug` output is verbose** → terminal spam | Only enable extra logging when --debug flag present; default `--init` is clean |

## Migration Plan

1. **Add browser image Containerfiles** (if not already present) to `images/chromium/`
2. **Implement `--diagnostics` handler** in `handlers.rs`; add CLI flag in `cli.rs`
3. **Extend `init.rs`** to build browser images
4. **Write cheatsheets** with provenance sections
5. **Add `@trace` annotations** throughout
6. **Test end-to-end**: `./build.sh --install && tillandsias --init --debug && tillandsias /project --diagnostics`
7. **Create delta specs** for `init-command` (what changed)
8. **Create new specs** for `cli-diagnostics` and `observability-convergence`

No breaking changes. Existing `--init` behavior unchanged (we add, not remove). Existing logs unchanged (we add `spec=` attribute, not modify format).

## Open Questions

- **Q**: Should `--diagnostics` also show tray process logs, or only container logs?
  - **A** (provisional): Container logs only. Tray logs go to `~/.local/share/tillandsias/logs/` if needed.
  
- **Q**: Should `--init --debug` skip security flags (like `--cap-drop=ALL`)? 
  - **A** (provisional): No. Keep security flags always on. `--debug` only adds verbose logging + longer timeouts.

- **Q**: Which projects' containers to tail in `--diagnostics <project>`? Just that project, or shared infra too?
  - **A** (provisional): Shared (proxy, git, inference) + project-specific (forge, browser-core, browser-framework for that project).
