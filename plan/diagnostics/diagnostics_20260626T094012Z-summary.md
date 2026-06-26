# Forge Diagnostics Summary — 2026-06-26T12:00:00Z

## Metadata

- **Source log**: `target/forge-diagnostics/diagnostics_20260626T094012Z.log`
- **Forge version**: 0.3.260626.3
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
- rustup
- flutter
- delve
- gradle
- nix
- wasm-tools
### Proposed enhancements
- rust: rustup — Rust toolchain manager absent — needed for multi-toolchain testing; project is Rust-based but relies on Fedora-packaged single rustc/cargo
- dart: flutter — Flutter SDK absent despite /opt/dart-sdk installed and flutter.md instructions present; GRADLE_USER_HOME configured for Flutter's Android build needs
- go: delve — Go debugger absent — GDB/LLDB present but delve is Go-native; GOPATH is configured expecting Go development
- other: gradle — Gradle binary absent despite OpenJDK 25 installed and GRADLE_USER_HOME pre-configured; needed for Java/Groovy builds
- other: nix — Nix absent despite nix-first.md instructions present and cheatsheet references to build/nix-flake-basics.md; crates.io-style reproducible builds depend on it
- wasm: wasm-tools — wasm-tools absent while wasm-pack and wasmtime are installed; the WebAssembly toolkit is needed for WASM module inspection and transformation

## Container-Start Stream (from .stderr.log companion)

- **Source**: `target/forge-diagnostics/diagnostics_20260626T094012Z.stderr.log`
- **Total launch events**: 10
- **state=running**: 4
- **state=failed**: 0

### Distinct stage → state pairings

```
event:container_launch stage=opencode state=exited
event:container_launch stage=opencode state=starting
event:container_launch stage=opencode-git state=running
event:container_launch stage=opencode-git state=starting
event:container_launch stage=opencode-inference state=running
event:container_launch stage=opencode-inference state=starting
event:container_launch stage=opencode-proxy state=running
event:container_launch stage=opencode-proxy state=starting
event:container_launch stage=router state=running
event:container_launch stage=router state=starting
```

### Typed-event arms

| event type | count |
|---|---:|
| event:container_stderr     | 980   |

#### container_stderr — top 5 containers by line count
```
    863 event:container_stderr container=tillandsias-inference
    102 event:container_stderr container=tillandsias-proxy
     15 event:container_stderr container=tillandsias-git-tillandsias
```
