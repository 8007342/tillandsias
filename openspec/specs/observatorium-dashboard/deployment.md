# Observatorium deployment

@trace spec:observatorium-dashboard, order:2066-obsv

Provenance: operator ruling 2026-11-09 (order 2066-obsv,
`plan/issues/observatorium-blind-design-2026-11-09/README.md`):

- **No auto-deploy anywhere.** Publishing is a manual `wrangler deploy` from
  the operator's own machine, after a release.
- **No Workers Builds trigger is connected, and none is ever connected.**
  Nothing builds on Cloudflare; no cloud build minutes are spent.

This replaces the 1661-vckd (Workers Builds from the repository) and
1798-khw6 (a stable promotion advances `deploy/observatorium`) flows. A stable
promotion (`scripts/promote-stable.sh`) no longer touches the deploy branch.

## What is where

| Thing | Where |
|---|---|
| Generator (no network, no dependencies) | `observatorium/site/build.mjs` |
| Its only input | `observatorium/history/snapshots.jsonl` (appended at the release cut) and `observatorium/data/claims.yaml` |
| Local preview output | `observatorium/dist/` (git-ignored) |
| Published site | the tree of `refs/heads/deploy/observatorium`: `wrangler.jsonc`, `package.json`, `verify.mjs`, `dist/**` |
| Worker | `tillandsias-observatorium`, static assets only, custom domain `observatorium.tillandsias.org` |

The deploy branch holds the BUILT site, not source (fleet lead, 2026-11-10).
Its `wrangler.jsonc` has no `build` command, so even a build triggered by
mistake would have nothing to run.

## The operator flow (after a release is cut)

1. **Check out the release, clean.**
   `git fetch --tags && git checkout v56.11.7.1`
2. **Preview it.** `node observatorium/site/build.mjs`, then serve
   `observatorium/dist/` with any static file server (or `preview.publish`
   with `app_dir: observatorium/dist` inside a forge) and read it. The build
   refuses (`refused:stale-snapshot`) if the history's last release is not the
   newest tag.
3. **Publish locally.** `node observatorium/site/publish.mjs v56.11.7.1`.
   It writes ONE commit on the local `refs/heads/deploy/observatorium` with:
   - `Observatorium-Release: <tag>`
   - `Observatorium-Snapshot: <sha256 of history/snapshots.jsonl>`
   - `Observatorium-Source: <release commit>`

   and refuses `already-published`, `older-release`, `dirty-tree`,
   `not-at-tag`, `stale-snapshot` or any honesty-lint violation. It moves no
   checkout, pushes nothing and deploys nothing.
4. **Push the ref by hand**, after `./build.sh --check` (the deploy-ref commit
   is not on `main`, so the pre-push gate wants a fresh stamp):
   `git push origin refs/heads/deploy/observatorium`
5. **Deploy from a checkout of the deploy branch.**
   ```
   git worktree add /tmp/obs-deploy deploy/observatorium
   cd /tmp/obs-deploy && npm install && npm run deploy
   ```
   `npm run deploy` is `node verify.mjs && wrangler deploy`. `verify.mjs`
   refuses (`missing-trailer`, `trailer-mismatch`, `snapshot-mismatch`) unless
   the commit's trailers name exactly the release and history digest that
   `dist/data/history.json` was built from. Wrangler authenticates with the
   operator's own login; nothing is stored in the repository.
6. **Rollback** is `git checkout <older deploy-branch commit>` in that
   worktree and `npm run deploy`. The branch itself only moves forward; the
   footer stamp on every page names the release it serves.

## Cloudflare settings

- The Worker has **no** Git connection and **no** build trigger. If the
  dashboard shows one under Settings → Build, disconnect it.
- `crates/tillandsias-headless/src/cloudflare_worker_deploy.rs` (order
  1853-qr4h) can create a Git connection and a deploy-branch trigger. It is not
  wired to any tool, and it must not be used for the observatorium. Whether it
  stays for user-project deploys is an open operator question (2026-11-10).
