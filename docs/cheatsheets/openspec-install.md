# OpenSpec Installation Cheatsheet

@trace spec:embedded-scripts

Source: [github.com/Fission-AI/OpenSpec](https://github.com/Fission-AI/OpenSpec) | [openspec.dev](https://openspec.dev/)

## Requirements

- **Node.js 20.19.0+** (`node --version` to check)

## Install Methods

| Method | Command |
|--------|---------|
| npm | `npm install -g @fission-ai/openspec@latest` |
| pnpm | `pnpm add -g @fission-ai/openspec@latest` |
| yarn | `yarn global add @fission-ai/openspec@latest` |
| bun | `bun add -g @fission-ai/openspec@latest` |
| Nix (run) | `nix run github:Fission-AI/OpenSpec -- init` |
| Nix (profile) | `nix profile install github:Fission-AI/OpenSpec` |

### Container (Tillandsias forge)

A project that records its openspec version in `openspec/cli-version` gets
exactly that version in the forge (`ensure_openspec_pinned`, `lib-common.sh`,
order 1441-myz3), installed into the forge's global npm prefix, and the
background harness refresher never moves it to `@latest`. Projects without a
pin get `@latest`. The pin moves only through the coordinator's deliberate
bump, which regenerates the committed `/opsx` sets in one change:
```bash
scripts/openspec-pin.sh check   # due:openspec-bump:<pin>-><latest> when npm has newer
scripts/openspec-pin.sh bump    # isolated config, writes the pin, never commits
scripts/openspec-pin.sh drift   # every tracked generatedBy == the pin
```
The older `$CACHE/openspec` and `/home/forge/.tools/openspec` install channels
are retired; nothing installs there.

## Verify

```bash
openspec --version
```

## Init a Project

```bash
cd your-project
openspec init                          # Interactive
openspec init --tools claude           # Pre-select AI tool
openspec init --tools claude,cursor    # Multiple tools
```

## Key CLI Commands

| Command | Purpose |
|---------|---------|
| `openspec init` | Initialize in project |
| `openspec update` | Refresh AI tool configs after upgrade |
| `openspec list` | List changes (default) or specs |
| `openspec list --specs` | List specs |
| `openspec show <name>` | Show change/spec details |
| `openspec view` | Interactive dashboard |
| `openspec validate --all` | Check everything for issues |
| `openspec status --change <name>` | Artifact progress for a change |
| `openspec status --change <name> --json` | Machine-readable status |
| `openspec instructions <artifact> --change <name>` | Get artifact creation instructions |
| `openspec archive <name>` | Archive completed change |
| `openspec archive <name> -y` | Archive without confirmation |

## Workflow Commands (used by /opsx skills)

```bash
# Create a new change
openspec new change "my-change"

# Check what artifacts need to be created
openspec status --change "my-change" --json

# Get instructions for creating an artifact
openspec instructions proposal --change "my-change" --json

# Archive after implementation
openspec archive "my-change" -y
```

## Nix Flake Integration

```nix
{
  inputs.openspec.url = "github:Fission-AI/OpenSpec";
  outputs = { openspec, ... }: {
    devShells.default = mkShell {
      buildInputs = [ openspec.packages.${system}.default ];
    };
  };
}
```
