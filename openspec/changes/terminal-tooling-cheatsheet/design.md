## Context
The forge image uses Nix for reproducible builds. All image packages are immutable. User-space tooling needs a strategy for ephemeral containers.

## Goals / Non-Goals
**Goals:** Rich terminal, documented package strategy, tools persist via cache
**Non-Goals:** Full IDE experience, GUI tools, language-specific dev environments

## Decisions

### Additional packages in flake.nix
Add to the forge image `contents` list:
- `less` — essential pager (git, man, etc.)
- `file` — identify file types
- `diffutils` — diff/cmp
- `patch` — apply patches
- `unzip` — extract archives
- `which` — find executables
- `procps` — ps, top, free, vmstat
- `strace` — syscall tracing (debug)
- `iproute2` — ip, ss (network debug)
- `openssh` — ssh client for git+ssh remotes
- `gnumake` — make (common build tool)

Note: `pico` is just `nano` — no separate package needed. Document the alias in the cheatsheet.

### Package manager cache strategy
Environment variables set in shell configs:
```bash
export NPM_CONFIG_PREFIX="$HOME/.cache/tillandsias/npm-global"
export CARGO_HOME="$HOME/.cache/tillandsias/cargo"
export GOPATH="$HOME/.cache/tillandsias/go"
export PIP_USER=1
export PYTHONUSERBASE="$HOME/.cache/tillandsias/pip"
```

These point global installs to the cache bind mount, which persists across container restarts. Project-local installs (npm install in a project dir) go to node_modules/ in the project dir (also persistent via bind mount).

PATH additions (in lib-common.sh and shell configs):
```bash
export PATH="$NPM_CONFIG_PREFIX/bin:$CARGO_HOME/bin:$GOPATH/bin:$PYTHONUSERBASE/bin:$PATH"
```

### Cheatsheet structure
1. Tool catalog (what's installed and what each tool does)
2. Package management (npm, cargo, pip patterns for ephemeral containers)
3. Terminal shortcuts (fish/bash/zsh)
4. Common workflows (git, file management, debugging)
5. Cache and persistence model
