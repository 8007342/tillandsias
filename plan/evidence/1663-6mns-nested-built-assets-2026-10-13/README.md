# 1663-6mns: publish_local serves a nested, built Wrangler assets directory

The operator's forge failed on yoga on 2026-10-13 (private project lakanoa).
Its wrangler.jsonc names `"assets": {"directory": "arkanoid-web-game/public"}`
and `"build": {"command": "npm ci && npm run build", "cwd": "arkanoid-web-game"}`.
Nothing of lakanoa is used here: the fixture is lakanoa-SHAPED.

## Red, end to end, on release v56.10.12.1 (`red-cold-start-v56.10.12.1/`)

`scripts/lua/cold-start-acceptance.lua` ran with a new step 7b on a sealed
nested substrate:
- a fresh install of v56.10.12.1;
- a forge on the public 8007342/macron.dev;
- macron.dev itself is served first (200).

7b writes the lakanoa shape into the forge's live worktree, as an agent would.
macron.dev's own root `public/` stays: serving it would be the WRONG root.

1. **Before the build:** correctly refused, `source_not_found: assets directory
   arkanoid-web-game/public (configured in wrangler.jsonc) does not exist yet;
   run its build.command first: npm ci && npm run build`.
2. **The build, run in the forge:** produced `arkanoid-web-game/public/index.html`.
3. **After the build:** `runtime_not_ready: managed runtime exited`. This is the
   bug. The driver ends `refused:cold-start-acceptance:lakanoa-shape-built-not-served`.

## Cause (measured, pinned wrangler 4.42.0)

`wrangler dev` RUNS `build.command` at startup (`[custom build] Running: ...`).
In the preview container only the approved config and the assets subset are
mounted, and there is no network, so the build fails and the runtime exits.
The tray wrote the project's raw config, `build` included, as the runtime
config.

## Fix

The config inspector already runs inside the pinned Wrangler image. It now
reads the raw config with Wrangler's own `experimental_readRawConfig` (JSONC
or TOML). When `build` is present, at the top level or under any `env`, it
emits the runtime config as JSON WITHOUT it. A TOML config's runtime name
gains `.json`, which the run args use for the written file and `--config`.

The agent builds in its forge, which the refusal already tells it to do. The
preview container never runs a project command.

## Green

`runtime-check.txt` runs the extracted CONFIG_INSPECTOR plus pinned
wrangler@4.42.0, with only the built nested `public/` present:

| case | runtime name | served | custom build ran |
|---|---|---|---|
| lakanoa-shaped `wrangler.jsonc` (with a comment) | wrangler.jsonc | `<title>LAKANOA-SHAPE-BUILT</title>` | 0 |
| the same as `wrangler.toml` | wrangler.toml.json | `<title>LAKANOA-SHAPE-BUILT</title>` | 0 |
| control: the UNSTRIPPED config | — | exits rc 1 | yes |

Unit tests: `a_stripped_runtime_config_runs_under_its_runtime_name` and
`the_inspector_strips_build_from_the_runtime_config`.

The end-to-end green (driver step 7b served with the marker) needs a release
that contains this fix: the driver installs a published release. I'll re-run
it against that release.
