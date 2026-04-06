## Why
Modern developers expect a rich terminal environment. The forge image needs standard tools pre-installed and a clear strategy for project-level package management in ephemeral containers.

## What Changes
- Add developer tools to flake.nix forge image: less, file, diffutils, patch, unzip, which, procps, strace, iproute2, openssh, gnumake
- Document package manager strategy: npm/cargo/pip project deps use project-local dirs that persist via bind mount
- Create docs/cheatsheets/terminal-tools.md with terminal best practices, tool catalog, and package management patterns
- Ensure npm prefix and cargo home point to cache dir for global tool installs
- Add @trace spec:forge-shell-tools annotations

## Capabilities
### New Capabilities
_None_
### Modified Capabilities
- `forge-shell-tools`: Additional tools in image, documented package management strategy

## Impact
- flake.nix — new packages added to forge image
- images/default/lib-common.sh — NPM_CONFIG_PREFIX, CARGO_HOME, GOPATH env vars pointing to cache
- images/default/shell/bashrc — add CARGO_HOME/GOPATH exports
- images/default/shell/config.fish — add CARGO_HOME/GOPATH exports
- images/default/shell/zshrc — add CARGO_HOME/GOPATH exports
- docs/cheatsheets/terminal-tools.md — new cheatsheet
