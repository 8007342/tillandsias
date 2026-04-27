---
tags: []  # TODO: add 3-8 kebab-case tags on next refresh
languages: []
since: 2026-04-25
last_verified: 2026-04-27
sources:
  - https://pnpm.io/cli/install
  - https://pnpm.io/workspaces
  - https://pnpm.io/motivation
authority: high
status: current

# v2 — tier classification (cheatsheets-license-tiered)
tier: pull-on-demand
summary_generated_by: hand-curated
bundled_into_image: false
committed_for_project: false
pull_recipe: see-section-pull-on-demand
---
# pnpm

@trace spec:agent-cheatsheets

## Provenance

- pnpm documentation (pnpm.io): <https://pnpm.io/cli/install> — pnpm install, pnpm add (-D/-O/-w), pnpm remove, pnpm run/exec/dlx, --filter patterns (name/path/graph selectors), -r recursive, pnpm store, pnpm why
- pnpm workspaces: <https://pnpm.io/workspaces> — pnpm-workspace.yaml, workspace:* protocol, --workspace-concurrency
- pnpm motivation (content-addressable store): <https://pnpm.io/motivation> — hard-link store architecture, one copy per (name, version)
- **Last updated:** 2026-04-25

**Version baseline**: pnpm 9.x (installed via `npm i -g --prefix=/usr` in forge image)
**Use when**: monorepos / disk-efficient package management.

## Quick reference

| Command | Effect |
|---|---|
| `pnpm install` (`pnpm i`) | Install deps from `package.json` + lockfile |
| `pnpm add <pkg>` / `-D` / `-O` | Add prod / dev / optional dependency |
| `pnpm remove <pkg>` | Drop a dependency |
| `pnpm run <script>` (`pnpm <script>`) | Run a `package.json` script |
| `pnpm exec <bin>` | Run a locally installed binary (no PATH munging) |
| `pnpm dlx <pkg>` | One-shot run of a remote package (npm's `npx` equivalent) |
| `pnpm -w add <pkg>` | Add to the workspace root, not a child package |
| `pnpm --filter <name> <cmd>` | Run command in a specific workspace package |
| `pnpm -r <cmd>` | Run command recursively across all workspace packages |
| `pnpm -r --parallel run dev` | Run a script in every package in parallel |
| `pnpm store path` / `prune` | Inspect / GC the content-addressable store |
| `pnpm why <pkg>` | Explain why a dep is in the tree |

## Common patterns

### Pattern 1 — install with content-addressable store

```bash
pnpm install              # populates ./node_modules via hard-links from ~/.local/share/pnpm/store
pnpm store status         # show store path + integrity
```

One copy on disk per (name, version, integrity), hard-linked into every project's `node_modules`.

### Pattern 2 — `--filter` to scope commands

```bash
pnpm --filter @scope/web build           # exact package
pnpm --filter "./packages/api*" test     # glob over paths
pnpm --filter "...@scope/web" build      # selected pkg + its deps
pnpm --filter "@scope/web..." build      # selected pkg + its dependents
```

### Pattern 3 — recursive scripts across the workspace

```bash
pnpm -r run build                 # serial, fail-fast
pnpm -r --parallel run dev        # all at once (good for watchers)
pnpm -r --workspace-concurrency=4 run test
```

### Pattern 4 — workspace protocol for internal deps

```json
// packages/web/package.json
{ "dependencies": { "@scope/lib": "workspace:*" } }
```

`workspace:*` (or `workspace:^`) resolves to the in-repo package; `pnpm publish` rewrites it to the actual version on release.

### Pattern 5 — `pnpm dlx` vs `npx`

```bash
pnpm dlx create-vite@latest my-app   # download + run, no install in cwd
pnpm exec eslint .                   # already-installed local bin
```

`dlx` always fetches fresh; `exec` runs from local `node_modules/.bin`.

## Common pitfalls

- **Hard-link store collisions on case-insensitive filesystems** — macOS APFS (default case-insensitive) and Windows NTFS can mangle hard-links between case-different paths in the store; symptoms are random `EEXIST` / corrupted modules. Fix: keep store and project on the same case-sensitive volume, or set `node-linker=isolated` then fall back to `hoisted` only if a dep demands it.
- **`--filter` pattern syntax differs from shell globs** — `--filter "*-web"` is a name pattern, `--filter "./apps/*"` is a path pattern, and `--filter "...pkg"` / `"pkg..."` are dependency-graph selectors. Mixing them with shell expansion silently filters nothing — always quote the argument.
- **`peerDependencies` strict-by-default** — pnpm refuses to silently auto-install peers; missing peers print warnings and can break builds. Either declare them explicitly or set `auto-install-peers=true` in `.npmrc` (default in pnpm 8+, but still worth verifying).
- **`hoist-pattern` / `public-hoist-pattern` foot-guns** — packages that rely on undeclared transitive deps (common in older React/webpack setups) break under pnpm's strict layout. Add the offenders to `public-hoist-pattern[]` in `.npmrc` rather than switching to `node-linker=hoisted` wholesale.
- **`pnpm-workspace.yaml` must exist for workspace mode** — without it, `--filter`, `-r`, and `workspace:*` all fail or behave like a single-package repo. Create it at the repo root with `packages: [ "packages/*", "apps/*" ]` before running anything else.
- **Lockfile drift between `pnpm` and `npm`/`yarn`** — `pnpm-lock.yaml`, `package-lock.json`, and `yarn.lock` must not coexist; pick one and delete the others, or pnpm will warn and tools downstream (Renovate, CI) will fight each other.
- **`pnpm install` inside a workspace child** — works, but always installs for the entire workspace. Use `pnpm --filter <name> add <pkg>` to add a dep to one package only; bare `pnpm add` in a child still adds to the right package, but `pnpm install` is global.

## Why pnpm vs npm

Content-addressable store on disk: one copy per (name, version) hard-linked into every project, so `node_modules` for ten apps costs roughly the same as one. Strict by default — no phantom deps, no flat hoisting surprises. First-class workspaces with `--filter` and `workspace:*`. Faster than npm/yarn classic on cold installs and dramatically faster on warm ones.

## Pull on Demand

> This cheatsheet's underlying source is NOT bundled into the forge image.
> Reason: upstream license redistribution status not granted (or off-allowlist).
> See `cheatsheets/license-allowlist.toml` for the per-domain authority.
>
> When you need depth beyond the summary above, materialize the source into
> the per-project pull cache by following the recipe below. The proxy
> (HTTP_PROXY=http://proxy:3128) handles fetch transparently — no credentials
> required.

<!-- TODO: hand-curate the recipe before next forge build -->

### Source

- **Upstream URL(s):**
  - `https://pnpm.io/cli/install`
- **Archive type:** `single-html`
- **Expected size:** `~1 MB extracted`
- **Cache target:** `~/.cache/tillandsias/cheatsheets-pulled/$PROJECT/pnpm.io/cli/install`
- **License:** see-license-allowlist
- **License URL:** https://pnpm.io/cli/install

### Materialize recipe (agent runs this)

```bash
set -euo pipefail
TARGET="$HOME/.cache/tillandsias/cheatsheets-pulled/$PROJECT/pnpm.io/cli/install"
mkdir -p "$(dirname "$TARGET")"
curl --fail --silent --show-error \
  "https://pnpm.io/cli/install" \
  -o "$TARGET"
```

### Generation guidelines (after pull)

1. Read the pulled file for the structure relevant to your project.
2. If the project leans on this tool/topic heavily, generate a project-contextual
   cheatsheet at `<project>/.tillandsias/cheatsheets/build/pnpm.md` using
   `cheatsheets/TEMPLATE.md` as the skeleton.
3. The generated cheatsheet MUST set frontmatter:
   `tier: pull-on-demand`, `summary_generated_by: agent-generated-at-runtime`,
   `committed_for_project: true`.
4. Cite the pulled source under `## Provenance` with `local: <cache target above>`.

## See also

- `build/npm.md` — npm baseline (scripts, workspaces, publish)
- `build/yarn.md` — yarn classic vs berry comparison
- `languages/typescript.md` — TS toolchain that typically lives in a pnpm monorepo
- `languages/javascript.md` — ESM vs CJS, package.json fields
