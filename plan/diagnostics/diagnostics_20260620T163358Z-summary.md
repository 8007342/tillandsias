# Forge Diagnostics Summary — 2026-06-20T16:34:26Z

## Metadata

- **Source log**: `target/forge-diagnostics/diagnostics_20260620T163358Z.log`
- **Forge version**: 0.3.260620.5
- **Host platform**: linux
- **Agent**: opencode
- **Completeness**: 25 / 25 checks passed (100%)

## Change vs Previous Run

Improvement: completeness rose from 0% to 100%

## Recommended Actions

- All forge capabilities nominal. Consider removing checked items from the diagnostics prompt.

## Forge Enhancement Candidates (→ curated-toolchain-backlog)

Candidates only — orchestrator approves against the privacy/isolation gate.

### Missing tools
- flutter
- delve
- staticcheck
- cargo-tarpaulin
- clangd
- mold
- perf
- javac
- dotnet
- nix
- gradle
### Proposed enhancements
- dart: flutter — Only Dart SDK present; Flutter framework required for mobile/web development workflow referenced in forge instructions
- go: delve — Go debugger absent; standard expectation for Go development alongside gopls
- go: staticcheck — Advanced Go static analysis; complements go vet for CI-quality checks
- rust: cargo-tarpaulin — Rust code coverage tool absent; complements cargo-nextest and cargo-deny for CI pipeline coverage gating
- other: clangd — C/C++ LSP server absent; only lldb present from LLVM toolchain — clangd enables IDE-grade code intelligence
- other: mold — Modern fast linker reduces Rust/C++ incremental build times in the forge
- other: perf — Linux profiler absent; useful for diagnosing performance regressions in native code
- other: javac — JDK compiler absent (only JRE java present); needed for Java project builds
- other: dotnet — .NET SDK entirely absent; blocks C#/F# workloads
- other: nix — Nix absent despite nix-first.md agent instructions and cheatsheets referencing nix workflows

## Container-Start Stream (from .stderr.log companion)

- **Source**: `target/forge-diagnostics/diagnostics_20260620T163358Z.stderr.log`
- **Total launch events**: 10
- **state=running**: 4
- **state=failed**: 0

### Distinct stage → state pairings

```
event:container_launch stage=opencode-git state=running
event:container_launch stage=opencode-git state=starting
event:container_launch stage=opencode-inference state=running
event:container_launch stage=opencode-inference state=starting
event:container_launch stage=opencode-proxy state=running
event:container_launch stage=opencode-proxy state=starting
event:container_launch stage=opencode state=exited
event:container_launch stage=opencode state=starting
event:container_launch stage=router state=running
event:container_launch stage=router state=starting
```

### Typed-event arms

| event type | count |
|---|---:|
| event:container_stderr     | 95   |

#### container_stderr — top 5 containers by line count
```
     84 event:container_stderr container=tillandsias-proxy
     11 event:container_stderr container=tillandsias-git-tillandsias
```
