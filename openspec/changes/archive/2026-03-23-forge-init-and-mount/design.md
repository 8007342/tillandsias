## Context

npm global installs go to the Nix store (read-only). OpenSpec must be installed to a writable location. OpenCode is already cached at `~/.cache/tillandsias/opencode/`. Use the same pattern for OpenSpec.

## Decisions

### D1: Cache layout

```
~/.cache/tillandsias/
├── opencode/opencode       # OpenCode binary (direct download)
├── openspec/               # OpenSpec npm prefix (npm install --prefix)
│   └── bin/openspec
└── nix/                    # Nix cache (future)
```

All under the mounted cache volume. Persists across container runs.

### D2: Idempotent init

The entrypoint checks:
1. Is OpenCode at `$CACHE/opencode/opencode`? If not → download. If yes → check for upgrade (weekly).
2. Is OpenSpec at `$CACHE/openspec/bin/openspec`? If not → `npm install --prefix $CACHE/openspec @fission-ai/openspec`. If yes → skip.
3. Add both to PATH.

### D3: Mount at src/<project>/

Change mount from:
```
-v ~/src/lakanoa:/home/forge/src
```
To:
```
-v ~/src/lakanoa:/home/forge/src/lakanoa
```

And set WORKDIR / cd to `/home/forge/src/lakanoa`. This makes OpenCode show `src/lakanoa:main` in its status bar.
