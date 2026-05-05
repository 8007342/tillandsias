---
tags: [terminal, shell, bash, tools, forge]
languages: [bash]
since: 2024-01-01
last_verified: 2026-04-27
sources:
  - https://www.gnu.org/software/bash/manual/html_node/The-Set-Builtin.html
authority: high
status: current
---

# Terminal Tools Cheatsheet

Quick reference for the Tillandsias Forge terminal environment.

@trace spec:forge-shell-tools

## Pre-installed Tools

### Shells
| Tool | Command | Description |
|------|---------|-------------|
| Fish | `fish` | Default shell — autocomplete, syntax highlighting |
| Bash | `bash` | POSIX-compatible shell |
| Zsh | `zsh` | Extended Bourne shell with plugins |

### File Management
| Tool | Command | Description |
|------|---------|-------------|
| eza | `eza --tree` | Modern `ls` with tree view and git integration |
| bat | `bat <file>` | Syntax-highlighted file viewer (replaces `cat`) |
| fd | `fd <pattern>` | Fast file finder (replaces `find`) |
| fzf | `fzf` | Fuzzy finder for files, history, anything |
| mc | `mc` | Midnight Commander — dual-pane file manager |
| tree | `tree` | Directory tree visualization |
| file | `file <path>` | Identify file types |
| less | `less <file>` | Pager for large files |

### Editors
| Tool | Command | Description |
|------|---------|-------------|
| vim | `vim <file>` | Modal text editor |
| nano | `nano <file>` | Simple text editor (also: `pico`) |

### Search
| Tool | Command | Description |
|------|---------|-------------|
| ripgrep | `rg <pattern>` | Fast regex search across files |
| grep | `grep <pattern>` | Standard pattern search |

### Version Control
| Tool | Command | Description |
|------|---------|-------------|
| git | `git status` | Git version control |
| gh | `gh pr list` | GitHub CLI — PRs, issues, repos |

### Development
| Tool | Command | Description |
|------|---------|-------------|
| Node.js | `node`, `npm` | JavaScript runtime + package manager |
| jq | `jq '.key'` | JSON processor |
| curl | `curl <url>` | HTTP client |
| wget | `wget <url>` | File downloader |
| make | `make` | Build automation |
| Nix | `nix build` | Reproducible builds (flakes enabled) |

### System
| Tool | Command | Description |
|------|---------|-------------|
| htop | `htop` | Interactive process monitor |
| strace | `strace -p <pid>` | System call tracer (debugging) |
| ps | `ps aux` | Process listing |
| free | `free -h` | Memory usage |
| ip | `ip addr` | Network interfaces |
| ssh | `ssh <host>` | SSH client for remote connections |

### Diff and Patch
| Tool | Command | Description |
|------|---------|-------------|
| diff | `diff a.txt b.txt` | Compare files line by line |
| patch | `patch < fix.patch` | Apply patches |
| unzip | `unzip archive.zip` | Extract ZIP archives |

### Navigation
| Tool | Command | Description |
|------|---------|-------------|
| zoxide | `z <partial>` | Smart directory jumping (learns from history) |
| cd | `cd <dir>` | Change directory |
| `..` | alias | Go up one directory |

## Package Management in Ephemeral Containers

Tillandsias containers are ephemeral (`--rm`) — they are destroyed on stop. User data persists via bind mounts:

- **Project files**: `/home/forge/src/<project>/` — mounted from host
- **Cache**: `/home/forge/.cache/tillandsias/` — mounted from host

### npm (Node.js)

```bash
# Project-local install (persists in project dir)
cd /home/forge/src/my-project
npm install              # -> node_modules/ in project dir

# Global install (persists in cache)
npm install -g <package> # -> ~/.cache/tillandsias/npm-global/
```

### Cargo (Rust)

```bash
# Build project (target dir in project)
cd /home/forge/src/my-rust-project
cargo build              # -> target/ in project dir

# Install tool (persists in cache)
cargo install <tool>     # -> ~/.cache/tillandsias/cargo/bin/
```

### pip (Python)

```bash
# Project-local install (with venv)
python -m venv .venv && source .venv/bin/activate
pip install <package>    # -> .venv/ in project dir

# User install (persists in cache)
pip install --user <package>  # -> ~/.cache/tillandsias/pip/
```

### Go

```bash
# Install tool (persists in cache)
go install <package>@latest   # -> ~/.cache/tillandsias/go/bin/
```

### Nix (any package)

```bash
# Temporary shell with any package
nix shell nixpkgs#<package>   # Available until container stops

# Build project
nix build                     # Uses flake in project dir
```

## Cache Persistence Model

```
~/.cache/tillandsias/
├── cargo/          # Rust: CARGO_HOME (cargo install targets)
├── claude/         # Claude Code binary + node_modules
├── go/             # Go: GOPATH (go install targets)
├── npm-global/     # npm -g installs
├── opencode/       # OpenCode binary
├── openspec/       # OpenSpec binary + node_modules
├── pip/            # pip --user installs
└── nix/            # Nix store cache
```

All cache directories persist across container restarts via the `~/.cache/tillandsias` bind mount. They are shared across all projects.

## Tips

- **Fish autocomplete**: Start typing, press right-arrow to accept suggestion from history
- **Fuzzy find files**: `Ctrl+T` (with fzf integration)
- **Search history**: `Ctrl+R` (fuzzy history search)
- **Smart cd**: `z project` jumps to recently visited directory matching "project"
- **Quick preview**: `bat --paging=never <file>` for inline preview without pager
- **Git diff with color**: `git diff | bat --language=diff`
- **Find and open**: `fd <pattern> | fzf | xargs vim`
- **JSON pretty-print**: `curl <api> | jq '.'`

## Provenance

- https://www.gnu.org/software/bash/manual/html_node/The-Set-Builtin.html — GNU Bash manual (The Set Builtin); `-e` (errexit), `-u` (nounset), `-o pipefail` options that govern safe script execution in forge entrypoints
- **Last updated:** 2026-04-27
