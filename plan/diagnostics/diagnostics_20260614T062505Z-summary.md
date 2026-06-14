# Forge Diagnostics Summary — 2026-06-14T06:26:00Z

## Metadata

- **Source log**: `target/forge-diagnostics/diagnostics_20260614T062505Z.log`
- **Forge version**: 0.3.260614.2
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
- clang/clang++
- clangd
- ripgrep
- fzf
- kubectl
- helm
- terraform
- podman
- sqlite3
- protoc
- buf
- delve
- golangci-lint
- gradle
- deno
- bun
- wasm-opt
- hadolint
- tmux
- eza
- tokei
- hyperfine
### Proposed enhancements
- other: clangd + clang/clang++ — C/C++ LSP server and compiler are standard in any dev forge; only gcc/g++ are present
- other: ripgrep — Fast recursive text search — notably absent despite fd being present
- other: fzf — Fuzzy finder for shell productivity; complements existing fd/bat/delta
- other: kubectl — Kubernetes CLI for cloud-native workloads, common in CI/CD pipelines
- other: terraform — Infrastructure-as-Code — absent despite being a common dev workflow
- other: protoc — Protobuf compiler for gRPC/API work; no protobuf tooling at all
- other: sqlite3 — Universal database CLI — absent; no database clients present
- go: golangci-lint — Go linting suite; gopls is present but no linter
- go: delve — Go debugger — gdb/lldb present but no Go-specific debugger
- java: gradle — Java build tool — mvn is present but gradle is not
- web: deno — Alternative JS/TS runtime; node + npm are present, deno and bun are absent
- other: tmux — Terminal multiplexer — standard for long-running forge sessions

## Container-Start Stream (from .stderr.log companion)

- **Source**: `target/forge-diagnostics/diagnostics_20260614T062505Z.stderr.log`
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
| event:container_stderr     | 194   |

#### container_stderr — top 5 containers by line count
```
    158 event:container_stderr container=tillandsias-proxy
     28 event:container_stderr container=tillandsias-inference
      8 event:container_stderr container=tillandsias-git-tillandsias
```
