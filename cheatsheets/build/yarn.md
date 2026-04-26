# yarn

@trace spec:agent-cheatsheets

## Provenance

- Yarn CLI reference (yarnpkg.com): <https://yarnpkg.com/cli> — yarn add/remove/run/exec/workspace/workspaces foreach/upgrade-interactive/set version; Berry (4.x) command set
- Yarn classic (1.x) documentation: <https://classic.yarnpkg.com/en/docs/cli/> — yarn install --frozen-lockfile, yarn add -D/-W, yarn workspaces run, classic-only commands
- Node.js Corepack documentation: <https://nodejs.org/api/corepack.html> — corepack enable, packageManager field in package.json, auto-version activation
- **Last updated:** 2026-04-25

**Version baseline**: yarn classic 1.22.x (installed via `npm i -g` in forge image). Berry (yarn 4.x) requires opt-in via Corepack.
**Use when**: an existing project chose yarn — otherwise npm/pnpm are usually preferred.

## Quick reference

| Task | yarn (classic) | npm equivalent |
|------|----------------|----------------|
| Install all deps | `yarn` or `yarn install` | `npm install` |
| Add runtime dep | `yarn add pkg` | `npm install pkg` |
| Add dev dep | `yarn add -D pkg` | `npm install -D pkg` |
| Add to workspace root | `yarn add -W pkg` | `npm install -w root pkg` |
| Remove dep | `yarn remove pkg` | `npm uninstall pkg` |
| Run script | `yarn run build` (or `yarn build`) | `npm run build` |
| Run binary | `yarn exec eslint .` | `npx eslint .` |
| Upgrade interactive | `yarn upgrade-interactive` | (no built-in equivalent) |
| Why is X installed? | `yarn why pkg` | `npm explain pkg` |
| Lockfile | `yarn.lock` | `package-lock.json` |
| CI install (frozen) | `yarn install --frozen-lockfile` | `npm ci` |
| Workspace command | `yarn workspaces foreach ...` (berry) / `yarn workspace <name> run X` (classic) | `npm -w <name> run X` |
| Enable berry | `corepack enable && yarn set version stable` | n/a |

## Common patterns

### Reproducible install in CI

```bash
yarn install --frozen-lockfile
```

Fails if `yarn.lock` would change. The classic equivalent of `npm ci` — use in CI and image builds. Do NOT use plain `yarn install` in CI; it silently rewrites the lockfile.

### Workspace script in a monorepo (classic)

```bash
yarn workspace @scope/web build
yarn workspaces run test   # run "test" in every workspace
```

`yarn workspaces run X` fans out to all workspaces. For Berry, use `yarn workspaces foreach -pt run X` (parallel + topological).

### Add a dep at the monorepo root

```bash
yarn add -W -D typescript
```

`-W` (`--ignore-workspace-root-check`) is required when adding to the root `package.json` of a workspace project. Without it yarn refuses, expecting you meant a child workspace.

### Upgrade deps interactively

```bash
yarn upgrade-interactive --latest
```

Curses-style picker showing current vs latest for every dep. `--latest` ignores semver ranges in `package.json`. Classic-only — Berry replaces this with `yarn up -i`.

### Opt into Berry (yarn 4) with Plug'n'Play

```bash
corepack enable
yarn set version stable    # writes .yarnrc.yml + .yarn/releases/
yarn install               # creates PnP loader, no node_modules
```

PnP skips `node_modules` entirely — packages are resolved from a single `.pnp.cjs` map. Faster, but breaks anything that walks `node_modules` directly.

## Common pitfalls

- **Classic vs Berry are different tools sharing a name** — `yarn add`, `yarn install`, `yarn workspaces` all behave differently between 1.x and 4.x. Check `yarn --version` first. Berry's `yarn workspaces foreach` does not exist in classic; classic's `yarn upgrade-interactive` does not exist in Berry (use `yarn up -i`).
- **`yarn.lock` is not interchangeable with `package-lock.json`** — different format, different resolution algorithm. Don't commit both. Pick one package manager per project and stick with it.
- **yarn ignores `package-lock.json`** — if a repo has both, yarn silently uses `yarn.lock` and lets `package-lock.json` rot. Delete the wrong one when you switch tools.
- **Mixing yarn and npm in the same project corrupts state** — different hoisting rules, different lockfile semantics, different `node_modules` layouts. One contributor running `npm install` after another ran `yarn` produces ghost dependencies that work locally but break in CI.
- **Berry's PnP breaks packages that walk `node_modules`** — tools like ESLint plugins, some webpack loaders, and most editor integrations expect `node_modules` to exist on disk. Without ESM/PnP support upstream you'll see `Cannot find module` errors. Fall back to `nodeLinker: node-modules` in `.yarnrc.yml` if a critical dep refuses to cooperate.
- **`yarn install` in CI is not reproducible** — it updates `yarn.lock` if anything resolves differently. Always use `--frozen-lockfile` (classic) or `--immutable` (berry) in CI and image builds.
- **`npm install -g yarn` in the forge** — the forge image already bakes yarn at `/usr/bin/yarn`. Re-installing globally writes to the ephemeral overlay and disappears on container stop. Use the baked version, or pin a specific version per-project via `corepack`.
- **Corepack auto-version surprises** — Node 16.10+ ships Corepack, which reads `packageManager` in `package.json` and silently downloads that exact yarn version on first invocation. Great for reproducibility, surprising when it adds startup latency or fails behind the proxy.

## See also

- `build/npm.md` — default Node package manager
- `build/pnpm.md` — fast, disk-efficient alternative with strict hoisting
- `languages/typescript.md` — most yarn projects are TS
- `languages/javascript.md` — base language
