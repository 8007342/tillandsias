# Forge Diagnostics Summary — 2026-06-04T00:24:08Z

## Metadata

- **Source log**: `target/forge-diagnostics/diagnostics_20260604T002348Z.log`
- **Forge version**: 0.2.260603.2
- **Host platform**: linux
- **Agent**: opencode
- **Completeness**: 25 / 25 checks passed (100%)

## Change vs Previous Run

Improvement: completeness rose from 0% to 100%

## Recommended Actions

- All forge capabilities nominal. Consider removing checked items from the diagnostics prompt.

## ⚠️ Isolation / Privacy Risks (investigate before any enhancement)

- {'risk': 'git PII exposure in environment', 'detail': 'GIT_AUTHOR_NAME=Tlatoāni, GIT_AUTHOR_EMAIL=bulloncito@gmail.com, GIT_COMMITTER_NAME=Tlatoāni, GIT_COMMITTER_EMAIL=bulloncito@gmail.com are exported in the container environment, exposing real user identity to all processes inside the container', 'severity': 'medium'}
- {'risk': 'writeable host bind mount at /home/forge/src/tillandsias', 'detail': 'Host btrfs subvolume mounted read-write into container; provides persistent host filesystem access from the forge', 'severity': 'low'}

## Forge Enhancement Candidates (→ curated-toolchain-backlog)

Candidates only — orchestrator approves against the privacy/isolation gate.

### Missing tools
- nix
- ripgrep
- eza
- direnv
- clang
- clang++
- clangd
- terraform
- tofu
- pre-commit
- bun
- deno
- pdm
- age
- sops
- golangci-lint
- staticcheck
- yaml-language-server
- bash-language-server
- eslint-lsp
### Proposed enhancements
- other: nix — nix-first.md instruction is present but nix is not installed; the forge cannot follow its own methodology guidance without it
- other: ripgrep — standard code-search tool expected alongside fzf, fd, and bat; used by fzf for rg-based file search
- other: direnv — per-directory environment loading complements nix-first methodology and per-project env management
- other: clang/clang++/clangd — clang-based C/C++ toolchain and LSP are standard alongside gcc; clangd is expected by LSP clients
- python: pre-commit — git hooks framework expected in production-quality repos; absent despite rich python toolchain
- other: terraform/tofu — infrastructure-as-code tooling expected in production-oriented forges; only ansible is absent too
- other: eza — modern ls replacement; fd and bat are present so eza completes the modern file-utils set
- other: age — modern encryption tool for secrets management; complements sops for pre-commit/CI secret workflows
- other: golangci-lint — standard Go linter aggregator; dlv/gopls/gofmt are present but linting is incomplete
- other: yaml-language-server — YAML LSP expected for GitHub Actions, k8s, and CI configs; no YAML validation LSP available
- other: bash-language-server — Bash LSP expected for shell script development; shellcheck may exist but LSP is standard

## Container-Start Stream (from .stderr.log companion)

- **Source**: `target/forge-diagnostics/diagnostics_20260604T002348Z.stderr.log`
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
| event:container_stderr     | 227   |

#### container_stderr — top 5 containers by line count
```
    216 event:container_stderr container=tillandsias-proxy
     11 event:container_stderr container=tillandsias-git-tillandsias
```
