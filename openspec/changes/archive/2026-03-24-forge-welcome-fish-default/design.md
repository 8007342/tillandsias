## Context

The forge container already has fish, zsh, bash, and a full suite of CLI tools installed (forge-shell-tools change). The entrypoint currently launches OpenCode or falls back to bash. The Terminal menu and --bash flag override the entrypoint with `bash`. We need to switch to fish and add a welcome message.

## Goals / Non-Goals

**Goals:**
- Launch fish as the default interactive shell in Terminal/--bash mode
- Display a colorful, informative welcome message showing environment context
- Show mount points with access levels (ro/rw/encrypted) in color
- Rotate beginner-friendly tips on each launch
- Show human-readable OS versions (not raw kernel versions)

**Non-Goals:**
- Changing the OpenCode entrypoint (that stays as-is)
- Making fish mandatory (users can type `bash` or `zsh` to switch)
- Adding a configuration UI for the welcome message

## Decisions

### Decision 1: Welcome script at `/usr/local/share/tillandsias/forge-welcome.sh`

**Choice**: A standalone bash script (yes, bash — for portability) baked into the image, sourced by fish's `config.fish` on interactive login. Fish runs the script via `bash /path/to/forge-welcome.sh` on startup.

**Output structure**:
```
┌──────────────────────────────────────────────────┐
│  🌱 Tillandsias Forge                             │
│                                                    │
│  Project:  lakanoa                                 │
│  Forge:    Fedora 43 (Minimal) + Fedora Silverblue 43 │
│                                                    │
│  Mounts:                                           │
│    /home/forge/src/lakanoa        ← ~/src/lakanoa  (rw) │
│    /home/forge/.config/gh         ← secrets/gh     (ro) │
│    /home/forge/.config/tillandsias-git ← secrets/git (ro) │
│    /home/forge/.cache/tillandsias ← cache          (rw) │
│                                                    │
│  Project mounted at /home/forge/src/lakanoa        │
│                                                    │
│  💡 Type help to learn about Fish shell            │
└──────────────────────────────────────────────────┘
```

Colors:
- Project name: bold cyan
- rw mounts: green
- ro mounts: red
- encrypted source: blue (future, for secrets)
- Tip keywords: bold/underline

### Decision 2: OS version detection

**Guest OS**: Parse `/etc/os-release` inside the container (Nix-built Fedora minimal).
**Host OS**: Pass as env var from the `podman run` command: `-e TILLANDSIAS_HOST_OS="Fedora Silverblue 43"`. The Rust handler reads `/etc/os-release` on the host and formats it.

### Decision 3: Rotating tips pool

~20 tips, one selected randomly per session via `$RANDOM`. Tips cover:
- Fish basics (help, tab, history search with Ctrl+R)
- Installed tools (mc, eza, bat, fd, fzf, vim, nano, htop, tree)
- Navigation (z for zoxide, cd -, ..)
- Keywords highlighted in bold

### Decision 4: fish as entrypoint

In `handlers.rs` and `runner.rs`, change `--entrypoint bash` to `--entrypoint fish`. Fish sources `~/.config/fish/config.fish` on startup, which calls the welcome script.

## Risks / Trade-offs

- **[fish not bash-compatible]** → Users who need bash can type `bash`. The `--bash` flag name stays for familiarity even though it launches fish.
- **[Welcome message noise]** → Kept concise (10-15 lines). The tip rotates so it doesn't feel stale.
