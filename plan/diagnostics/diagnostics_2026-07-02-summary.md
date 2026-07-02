# Forge Diagnostics Summary — 2026-07-02T19:43Z

## Cycle Metadata

| Field | Value |
|---|---|
| UTC | 2026-07-02T19:43:42Z |
| Host kind | `forge` (TILLANDSIAS_HOST_KIND=forge) |
| Kernel | Linux 6.6.114.1-microsoft-standard-WSL2 x86_64 |
| Distro | Fedora 44 Container Image |
| User | forge (uid 1000) |
| CPU | 16 cores (AMD Ryzen AI 7 350) |
| RAM | 7.3 GiB total, 4.5 GiB free |
| Disk | 947 GiB available (overlay, ~1% used) |
| Container runtime | Podman (overlay filesystem) |
| Active branch | windows-next (up to date with origin) |

## Agent Runtimes

| Agent | Version | Location |
|---|---|---|
| OpenCode | 1.16.2 | `/usr/local/sbin/opencode` |
| Claude Code | 2.1.168 | `/usr/local/sbin/claude` |
| Codex | 0.137.0 | `/usr/local/sbin/codex` |
| OpenSpec | 1.4.1 | `/usr/local/sbin/openspec` |

## Compilers & Toolchains

| Tool | Version | Status |
|---|---|---|
| gcc | 16.1.1 (Red Hat 16.1.1-2) | ✅ |
| g++ | 16.1.1 (Red Hat 16.1.1-2) | ✅ |
| clang | — | ❌ Not installed (clang-libs present) |
| rustc | 1.96.0 (Fedora 1.96.0-1.fc44) | ✅ Fedora package, no rustup |
| go | 1.26.4-2 (Fedora) | ✅ |
| javac (JDK) | — | ❌ Only headless JRE installed |
| java (JRE) | OpenJDK 25.0.3 | ✅ |
| dart | 3.12.1 (stable) | ✅ `/opt/dart-sdk/bin/dart` |
| flutter | — | ❌ `FLUTTER_ROOT=/opt/flutter` set but SDK absent |

## Runtimes & Interpreters

| Tool | Version | Status |
|---|---|---|
| python3 | 3.14.6 | ✅ |
| node | v22.22.2 | ✅ (symlink: node → node-22) |
| perl | v5.74 | ✅ |
| ruby | — | ❌ Not installed |
| deno | — | ❌ Not installed |

## Build Systems

| Tool | Version | Status |
|---|---|---|
| make | 4.4.1 | ✅ |
| cmake | 4.3.0 | ✅ |
| cargo | 1.96.0 | ✅ |
| npm | 10.9.7 | ✅ |
| mvn | 3.9.11 (Red Hat) | ✅ |
| pnpm | 10.33.0 | ✅ |
| yarnpkg | 1.22.22 | ✅ |
| just | 1.53.0 | ✅ |
| ninja | — | ❌ Not installed |
| meson | — | ❌ Not installed |

## Cargo Ecosystem (additional tools)

| Tool | Version | Status |
|---|---|---|
| cargo-deny | 0.18.9 | ✅ |
| cargo-nextest | 0.9.137 | ✅ |
| cargo-chef | 0.1.77 | ✅ |
| cargo-watch | 8.5.3 | ✅ |
| cargo-audit | 0.22.2 | ✅ |
| cargo-llvm-cov | 0.8.7 | ✅ |
| cargo-semver-checks | 0.48.0 | ✅ |
| cargo-expand | 1.0.122 | ✅ |
| cargo-criterion | 1.1.0 | ✅ |
| cargo-wasi | 0.1.28 | ✅ |
| cargo-outdated | 0.19.0 | ✅ |
| wasm-pack | 0.15.0 | ✅ |
| wasmtime | 45.0.0 | ✅ |
| watchexec | 2.5.1 | ✅ |

## Language Servers & Formatters

| Tool | Version | Status |
|---|---|---|
| rust-analyzer | 1.96.0 | ✅ |
| gopls | bundled with Go | ✅ |
| typescript-language-server | 5.3.0 | ✅ `/usr/local/sbin` |
| eslint | v10.4.1 | ✅ `/usr/local/sbin` |
| prettier | 3.8.3 | ✅ `/usr/local/sbin` |
| marksman (Markdown LSP) | 2026-02-08 | ✅ `/usr/local/sbin` |
| black | 25.1.0 | ✅ |
| ruff | 0.15.16 | ✅ |
| pylint | 4.0.5 | ✅ |
| yamllint | 1.38.0 | ✅ |
| pyright | 1.1.410 | ✅ |
| bandit | 1.9.2 | ✅ |
| shellcheck | — | ✅ |
| shfmt | — | ✅ |
| clangd | — | ❌ Not installed |
| typos-cli | 1.47.2 | ✅ |
| vale | 3.14.2 | ✅ |
| actionlint | 1.7.12 | ✅ |

## Shells

| Shell | Version | Status |
|---|---|---|
| bash | 5.3.9 | ✅ |
| zsh | 5.9 | ✅ |
| fish | 4.6.0 | ✅ |

## Utilities

| Tool | Version | Status |
|---|---|---|
| git | 2.55.0 | ✅ |
| gh | 2.94.0 | ✅ |
| curl | 8.18.0 | ✅ |
| wget | 2.2.1 (Wget2) | ✅ |
| jq | 1.8.1 | ✅ |
| yq | v4.47.1 | ✅ |
| rg (ripgrep) | 14.1.1 | ✅ |
| fd (fd-find) | 10.4.2 | ✅ |
| fzf | 0.73.1 | ✅ |
| eza | modern ls replacement | ✅ |
| bat | 0.26.1 | ✅ |
| htop | 3.4.1 | ✅ |
| httpie | 3.2.4 | ✅ |
| zoxide | 0.9.8 | ✅ |
| git-delta | 0.19.1 | ✅ |
| git-lfs | 3.7.1 | ✅ |
| ssh | OpenSSH | ✅ |
| nano | 8.7.1 | ✅ |
| tar | 1.35 | ✅ |
| unzip | — | ✅ |
| vi (vim-minimal) | 9.2.725 | ✅ (vim not available, vi is) |
| gdb | 17.1 | ✅ |
| lldb | 22.1.8 | ✅ |
| strace | 7.1 | ✅ |
| ltrace | 0.8.1 | ✅ |
| valgrind | 3.27.1 | ✅ |
| heaptrack | 1.5.0 | ✅ |
| dlv (delve) | — | ✅ |
| which | — | ❌ Not installed (alternative: `command -v`) |
| vim | — | ❌ Not installed (vim-minimal provides vi only) |
| tmux | — | ❌ Not installed |
| podman | — | ❌ Expected — inside container |
| docker | — | ❌ Expected — inside container |

## Package Managers

| Tool | Version | Status |
|---|---|---|
| dnf (dnf5) | 5.4.2.1 | ✅ |
| rpm | 6.0.1 | ✅ |
| pip3 | 26.0.1 | ✅ |
| uv | 0.11.25 | ✅ |
| poetry | 2.3.1 | ✅ |
| pipx | — | ✅ |

## Infrastructure & Network Services

| Service | Address | Status | Notes |
|---|---|---|---|
| DNS | 10.0.42.1 | ✅ | Podman DNS |
| HTTP/S Proxy | proxy:3128 | ✅ | Squid caching proxy, allowlisted domains |
| Git Mirror | git-service:9418 | ✅ | Bare mirror, TCP reachable, `git ls-remote` exits 0 |
| Vault | vault:8200 | ✅ | Responds on HTTPS: initialized, unsealed, v1.18.5 |
| Inference (Ollama) | inference:11434 | ❌ UNREACHABLE | No response (may still be starting or not deployed) |
| Router | opencode.\<project\>.localhost:8080 | host-only | Per-project router |
| External GitHub | github.com:443 | ✅ | HTTP 200 via proxy |

## Environment Configuration

| Variable | Value |
|---|---|
| TILLANDSIAS_HOST_KIND | forge |
| TILLANDSIAS_PROJECT | tillandsias |
| CARGO_HOME | /home/forge/.cache/tillandsias-project/cargo |
| GOPATH | /home/forge/.cache/tillandsias-project/go |
| GOROOT | ❌ Not set |
| JAVA_HOME | ❌ Not set |
| ANDROID_HOME | ❌ Not set |
| FLUTTER_ROOT | /opt/flutter (❌ SDK absent) |
| SSL_CERT_FILE | /tmp/tillandsias-combined-ca.crt (combined CA chain) |
| HTTP_PROXY | http://proxy:3128 |
| HTTPS_PROXY | http://proxy:3128 |
| NO_PROXY | localhost,127.0.0.1,...,10.0.42.0/24 |
| PATH | Includes cargo, go, npm, dart, openspec, system paths |
| LANG | ❌ Not set (may affect locale-dependent tools) |

## Credential Channel

| Check | Result |
|---|---|
| `scripts/check-credential-channel.sh` | `ok:gh-credentials-store` ✅ |
| GH_TOKEN / GITHUB_TOKEN | Absent (intentional — forge uses git-service mirror) |
| `.git/.gh-credentials` | Present (41 bytes) |

## Caching Directories (all under /home/forge/.cache/tillandsias-project/)

| Cache | Path |
|---|---|
| npm | /home/forge/.cache/tillandsias-project/npm/ |
| cargo | /home/forge/.cache/tillandsias-project/cargo/ |
| go | /home/forge/.cache/tillandsias-project/go/ |
| pip | /home/forge/.cache/tillandsias-project/pip/ |
| uv | /home/forge/.cache/tillandsias-project/uv/ |
| yarn | /home/forge/.cache/tillandsias-project/yarn/ |
| pub (Dart) | /home/forge/.cache/tillandsias-project/pub/ |
| gradle | /home/forge/.cache/tillandsias-project/gradle/ |
| maven | /home/forge/.cache/tillandsias-project/maven/ |
| pnpm | /home/forge/.cache/tillandsias-project/pnpm/ |

## Structural Observations

### Configuration Gaps
1. **FLUTTER_ROOT set but Flutter SDK absent**: ENV FLUTTER_ROOT=/opt/flutter is exported in Containerfile but the Flutter SDK is not installed. The /opt/flutter/ directory does not exist.
2. **JAVA_HOME not set**: OpenJDK 25 JRE is installed but JAVA_HOME is not exported.
3. **JDK absent**: Only headless JRE installed; no javac/JDK for compilation.
4. **Clang not installed**: clang-libs is present (for Rust LLVM linkage) but clang/clang++/clangd are not.
5. **LANG not set**: May break some locale-sensitive tools.

### Binary Layout
- Tools are in `/usr/sbin/` with symlinks to `/usr/bin/` — non-standard layout but functional.
- `which` is not installed; `command -v` works as replacement.
- Tools installed via `npm install -g --prefix /usr/local` land in `/usr/local/sbin/`.

### Git Push Path
- Direct HTTPS push to GitHub fails (no interactive terminal for credential prompt).
- Forge uses git-service mirror (`git-service:9418`) for authenticated pushes. The `.gh-credentials` token is consumed by the mirror service, not by local git.
- `.git/config` has `email = bulloncito@gmail.com` and `name = bullo` for commit attribution.

### Service Health
- Proxy is operational (HTTP 400 on direct access is expected for a forward proxy).
- Vault is operational, accepting HTTPS on port 8200, initialized and unsealed.
- Inference (Ollama) on port 11434 is unreachable — this is the one infrastructure gap.
- Git mirror is TCP-reachable on port 9418.

## Classification

This diagnostics file is a forge capability baseline for the 2026-07-02 runtime.
All findings are observational; enhancement proposals should be filed separately
as `plan/issues/` work items with proposed → reviewed → approved → implemented
state machine per `diagnose-forge` skill discipline.
