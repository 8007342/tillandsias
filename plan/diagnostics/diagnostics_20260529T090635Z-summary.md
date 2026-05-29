# Forge Diagnostics Summary — 2026-05-29T09:06:47Z

## Metadata

- **Source log**: `target/forge-diagnostics/diagnostics_20260529T090635Z.log`
- **Forge version**: 0.2.260528.1
- **Host platform**: unknown
- **Agent**: unknown
- **Completeness**: 25 / 25 checks passed (100%)

## Change vs Previous Run

Improvement: completeness rose from 0% to 100%

## Recommended Actions

- All forge capabilities nominal. Consider removing checked items from the diagnostics prompt.

## ⚠️ Isolation / Privacy Risks (investigate before any enhancement)

- {'risk': 'proxy_routed_external_traffic', 'detail': 'external_curl returned 403 (proxy responded) — network path to external hosts exists; block depends on proxy policy, not network isolation'}
- {'risk': 'prompt_leak_via_env', 'detail': 'TILLANDSIAS_OPENCODE_PROMPT env var contains the full system prompt text, visible in environment dumps'}
- {'risk': 'host_filesystem_write_access', 'detail': 'Host btrfs subvolume mounted at /home/forge/src/tillandsias (TILLANDSIAS_PROJECT_HOST_MOUNT=1) gives writable host FS access'}
- {'risk': 'secrets_mount_point_exists', 'detail': '/run/secrets is a writable tmpfs (6.2G); currently empty but available for credential injection'}

## Forge Enhancement Candidates (→ curated-toolchain-backlog)

Candidates only — orchestrator approves against the privacy/isolation gate.

### Missing tools
- clang/clang++
- flutter
- delve
- cargo-expand
- cargo-llvm-cov
- nix
- eslint
- prettier
- binaryen (wasm-opt)
- tmux
- yq
### Proposed enhancements
- c-cpp: clang/clang++/lld — CGO, Rust FFI, and native module compilation require LLVM toolchain
- dart: flutter — Dart SDK (3.12.1) present; Flutter needed for Dart UI development — referenced in forge instructions but not installed
- go: delve — Go 1.x present with gopls but no debugger
- rust: cargo-expand — Standard macro expansion tool; rust-analyzer and cargo-watch present, expand is a common gap
- rust: cargo-llvm-cov — Rust code coverage tooling; cargo-nextest present but no coverage support
- other: nix — TILLANDSIAS_SHARED_CACHE=/nix/store set, nix-first.md instructions exist, but nix not installed
- web: eslint + prettier — Node 22 and tsc present; standard JS/TS formatting and linting missing
- wasm: binaryen (wasm-opt) — wasm-pack and rustc wasm32 targets present but no wasm optimizer for production builds

## Container-Start Stream (from .stderr.log companion)

- **Source**: `target/forge-diagnostics/diagnostics_20260529T090635Z.stderr.log`
- **Total launch events**: 8
- **state=running**: 3
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
```

### Typed-event arms

| event type | count |
|---|---:|
| event:container_stderr     | 110   |

#### container_stderr — top 5 containers by line count
```
    102 event:container_stderr container=tillandsias-proxy
      8 event:container_stderr container=tillandsias-git-tillandsias
```
