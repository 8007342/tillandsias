---
tags: []  # TODO: add 3-8 kebab-case tags on next refresh
languages: []
since: 2026-04-25
last_verified: 2026-04-27
sources:
  - https://docs.npmjs.com/cli/v10/commands
  - https://docs.npmjs.com/cli/v10/using-npm/workspaces
authority: high
status: current

# v2 — tier classification (cheatsheets-license-tiered)
tier: bundled
summary_generated_by: hand-curated
bundled_into_image: true
committed_for_project: false
---
# npm

@trace spec:agent-cheatsheets

## Provenance

- npm CLI documentation v10 (docs.npmjs.com): <https://docs.npmjs.com/cli/v10/commands> — npm init/install/-D/-E/--omit=dev/ci/update/outdated/audit/run/exec(npx)/pack/publish/version/view/ls/workspaces
  local: `cheatsheet-sources/docs.npmjs.com/cli/v10/commands`
- npm workspaces documentation: <https://docs.npmjs.com/cli/v10/using-npm/workspaces> — -w flag, --workspaces-update, hoisting behavior
  local: `cheatsheet-sources/docs.npmjs.com/cli/v10/using-npm/workspaces`
- **Last updated:** 2026-04-25

**Version baseline**: npm 10.x bundled with Node.js 22 (Fedora 43 `nodejs` package). `yarn` and `pnpm` are also baked into the forge image.
**Use when**: managing JavaScript / TypeScript packages — installing deps, running scripts, publishing.

## Quick reference

| Command | Effect |
|---|---|
| `npm init -y` | Create `package.json` with defaults |
| `npm install` (`npm i`) | Install all deps from `package.json` / `package-lock.json` |
| `npm i <pkg>` | Add to `dependencies` |
| `npm i -D <pkg>` | Add to `devDependencies` |
| `npm i -E <pkg>` | Pin exact version (no `^`) |
| `npm i --omit=dev` | Production install (skip devDeps) |
| `npm uninstall <pkg>` | Remove + prune lockfile |
| `npm ci` | Clean install from lockfile (CI-only; fails if lockfile drifts) |
| `npm update [pkg]` | Bump within semver range in `package.json` |
| `npm outdated` | Show packages with newer versions available |
| `npm audit [fix]` | Vuln scan; `--force` may rewrite ranges |
| `npm run <script>` | Run a `package.json` `scripts` entry |
| `npm test` / `npm start` | Shortcuts for `scripts.test` / `scripts.start` |
| `npm exec <bin>` / `npx <bin>` | Run a package binary (downloads if needed) |
| `npm pack` | Produce the `.tgz` that would be published |
| `npm publish [--access public]` | Publish to registry (scoped pkgs need explicit access) |
| `npm version <major\|minor\|patch>` | Bump version, commit, tag |
| `npm view <pkg> [field]` | Inspect a registry package (`versions`, `dist-tags`) |
| `npm ls [--depth=0]` | Show installed dep tree |
| `npm config get <key>` | Read an npm config (e.g. `prefix`, `registry`) |
| `npm i -w <pkg>` | Install into a specific workspace |
| `npm run build --workspaces` | Run script across all workspaces |

## Common patterns

### Install + always commit the lockfile
```bash
npm install lodash
git add package.json package-lock.json
```
The lockfile pins the exact dep tree; without it, teammates and CI resolve different transitive versions. Treat `package-lock.json` as source code.

### Run scripts (the modern Make)
```json
{
  "scripts": {
    "build": "tsc -p tsconfig.json",
    "lint": "eslint .",
    "test": "node --test test/*.test.js",
    "dev": "node --watch src/index.js"
  }
}
```
Then `npm run build`, `npm test`, `npm run dev`. Scripts inherit `node_modules/.bin` on `PATH`, so local binaries (`tsc`, `eslint`) Just Work without `npx`.

### `npx` for one-shot tools
```bash
npx create-vite@latest my-app
npx tsc --init
```
Runs a binary without installing globally — fetches into `~/.npm/_npx/` cache, executes, exits. Append `@latest` (or a version) to bypass any cached older copy.

### Workspaces (monorepo, no extra tool)
```json
{ "workspaces": ["packages/*", "apps/*"] }
```
```bash
npm install                       # install all workspaces + hoist
npm i react -w apps/web           # add to one workspace
npm run build --workspaces        # run build in every workspace
npm run test -w packages/core     # run test in one
```
Hoisting puts shared deps in the root `node_modules/`. Use `--workspaces-update=false` if you want to avoid re-resolving everything on a single-workspace install.

### Publishing a scoped package
```bash
npm version patch                 # 1.2.3 -> 1.2.4, commits + tags
npm publish --access public       # scoped pkgs default to private
git push --follow-tags
```
`--access public` is required the first time you publish `@scope/name` — otherwise npm errors out demanding a paid private plan.

## Common pitfalls

- **`npm install -g` fails in the forge** — writes to `/usr` (or `npm config get prefix`), which is image state and read-only on the overlay. Either install per-project (preferred), use the agents already baked at `/opt/agents/` (claude / opencode / openspec), or set a writable prefix like `npm config set prefix ~/.npm-global` and add `~/.npm-global/bin` to `PATH` (lost on container stop unless committed to the image).
- **Peer-dep warnings became errors** — npm 7+ auto-installs peer deps and refuses conflicting trees with `ERESOLVE`. Resolve by aligning versions, or escape with `--legacy-peer-deps` (npm 6 behavior, often needed for older React ecosystems). Don't reach for `--force` — it overwrites the lockfile.
- **`devDependencies` ship by default** — plain `npm install` installs everything. For production / Docker images, use `npm ci --omit=dev` (or `NODE_ENV=production npm install`). Otherwise your image carries every linter and test framework.
- **`package-lock.json` merge conflicts** — never hand-edit. Resolve by taking either side, then `rm package-lock.json && npm install` (or `npm install --package-lock-only` for a no-fetch refresh). For long-running branches, regenerate before merging.
- **`npm version` has side effects** — it `git commit`s and `git tag`s by default. In a non-git directory it errors. Use `--no-git-tag-version` if you only want the file edit. The `preversion` / `version` / `postversion` scripts also run.
- **`node_modules/` is enormous and ephemeral** — never commit it. The forge cache lives at `~/.npm/`, also ephemeral on container restart. For repeat installs in CI, mount or restore the npm cache, not `node_modules`.
- **Scripts run in `sh`, not `bash`** — `npm run` invokes scripts via `sh -c` (BusyBox-style on minimal images). `[[ ... ]]`, arrays, `set -o pipefail` etc. silently misbehave. Prefer cross-platform JS (`node script.js`) or call `bash -c '...'` explicitly.
- **`npm ci` deletes `node_modules` first** — it's atomic and strict (lockfile must match `package.json`), but it nukes the existing tree, so it's slower than `npm install` for incremental dev. Reserve it for CI and reproducible builds.
- **`npx` runs whatever it finds** — if a binary name matches a malicious package, `npx <name>` will download and execute it. Pin with `npx <name>@<version>` and prefer `npm exec --no-install -- <name>` (errors if not local) for hot paths.
- **Lifecycle scripts run on install** — `preinstall` / `install` / `postinstall` from any dep execute on `npm install`. Audit with `npm install --ignore-scripts` if you don't trust the tree (then run scripts selectively). The forge's offline proxy provides some protection, but `--ignore-scripts` is the only hard stop.

## Forge-specific

- `npm install -g` will fail because the global prefix lives on the image's read-only layer. Use per-project installs and `npx`, or rely on the baked agents at `/opt/agents/` (`claude`, `opencode`, `openspec`).
- The npm cache (`~/.npm/`) is ephemeral — every fresh forge attach re-downloads. The enclave proxy caches the registry HTTP responses, so the second pull within a project is fast even if `node_modules` was wiped.
- Registry traffic flows through the enclave proxy with a domain allowlist; `registry.npmjs.org` is allowed by default. Custom registries need a proxy config update — `npm config set registry <url>` alone won't bypass the allowlist.

## See also

- `build/pnpm.md` — fast, disk-efficient alternative (content-addressed store)
- `build/yarn.md` — alternative package manager (Berry / classic)
- `languages/javascript.md` — modern JS in the forge
- `languages/typescript.md` — typed superset, usually installed via npm
- `languages/json.md` — `package.json` / `package-lock.json` format
- `runtime/forge-container.md` — why per-project installs (not `-g`) in the forge
