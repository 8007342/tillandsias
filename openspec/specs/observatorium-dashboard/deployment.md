# Observatorium deployment

@trace spec:observatorium-dashboard, order:1661-vckd, order:1798-khw6

Provenance: operator direction 2026-10-13 ("the absolute easiest
Flutter-to-Cloudflare path"). Cloudflare Workers Builds deploys straight from
the repository. There are no GitHub Actions, no Cloudflare token in GitHub,
and no mirror allowlist change. The Cloudflare facts below were checked against
Cloudflare's documentation on 2026-10-13 (links at the end).

## Cloudflare dashboard settings (the operator sets these once)

Workers & Pages → Create → Import a repository → `8007342/tillandsias`, then
**Settings → Build**:

| Setting | Value |
|---|---|
| Production branch | `deploy/observatorium` |
| Builds for non-production branches | **Off**: delete the "Deploy non-production branches" trigger the import wizard creates |
| Root directory | `observatorium` |
| Build command | `npm run build` |
| Deploy command | `npx wrangler deploy` (the default; leave it) |
| Build watch paths | include `*`, exclude nothing |
| Build variables | none needed |
| Build cache | Enable (see "Caching" for what it does and does not keep) |

### Only a stable promotion deploys (order 1798-khw6)

Provenance: operator direction 2026-10-19. The first Worker used the import
wizard's defaults: production on `main` plus a preview trigger on every other
branch, all paths. Every push to `linux-next`, the platform branches and
`work/*` started a ~5-minute build, and the operator deleted the Worker to stop
the burn. Cloudflare's builds list for `tillandsias-org`, the sibling site,
shows the same two default triggers.

The production branch is `deploy/observatorium`, and nothing writes it except
`scripts/promote-stable.sh` (step 4, through `scripts/advance-deploy-ref.sh`).
Workers Builds cannot watch the `stable` tag, so this branch follows it:

- **promote:** the branch fast-forwards to the release commit;
- **demote, or an older release:** the git mirror refuses branch rewinds, so
  a restore commit is pushed instead (tree = the release's, first parent =
  the release, second parent = the old tip);
- **same tree already deployed:** nothing is pushed.

Watch paths stay at `*` because every promotion should deploy. The build reads
`openspec/specs`, `plan/` and git history as well as `observatorium/`, so a
narrower filter would skip real changes. A promotion jump of 20 or more
commits always builds anyway (Cloudflare's watch-path bypass).

Redeploying by hand, for example after a failed build: "Retry build" on the
Worker, or `scripts/advance-deploy-ref.sh <release-tag> --label <release-tag>`.

The **Build command must be set.** Workers Builds does NOT run
`wrangler.jsonc`'s `build.command`. Cloudflare's configuration page says:
"Currently, Workers Builds does not honor the configurations set in Custom
Builds within your Wrangler configuration file." `build.command` stays in
`wrangler.jsonc` for a local `npx wrangler deploy`.

The custom domain comes from `wrangler.jsonc`: `observatorium.tillandsias.org`
as a Workers Custom Domain, with `workers_dev: false`. It is an assets-only
Worker; no apex route is configured. Workers Builds uses the Wrangler version
pinned in `package.json`.

## What one build does (`npm run build` = `node scripts/build.mjs`)

The same script runs on Cloudflare, in a forge, in a toolbox, and for a local
`wrangler deploy`. Every download is pinned by URL and SHA-256 (`PINS` in
`scripts/build.mjs`):

1. **`tillandsias-plan`:** a given `TILLANDSIAS_PLAN_BIN`, or else built from
   this checkout with `cargo build --release -p tillandsias-plan`. When no cargo
   is present (Workers Builds lists none), a pinned `rustup-init` installs the
   toolchain `../rust-toolchain.toml` names.
2. **Git history:** if the clone is shallow, `git fetch --unshallow` is tried.
   A shallow history that cannot be deepened is recorded as an explicit gap.
3. **Live metrics:** collection with a fresh CentiColon grade
   (`scripts/centicolon-grade.sh`), then precomputation against the COMMITTED
   history (`history/snapshots.jsonl`). The live observation is display-only
   and is never written back.
4. **Flutter:** the forge's managed sibling command when a forge is attached,
   otherwise the pinned Flutter SDK, then `flutter pub get` and
   `flutter build web --release` into `build/web` (the assets directory).

`npm run metrics` stops after step 3.

## History: durable storage is the repository

`history/snapshots.jsonl` holds one line per release, each naming its tag
(`"release":"v…"`). The release cut appends it
(`node scripts/build.mjs --release-snapshot <tag>`; the
merge-to-main-and-release skill, §8) and commits it with the release ledger.
A deploy only reads it. Workers Builds has no push credential and is not
given one.

## Workers Builds environment (Cloudflare docs, 2026-10-13)

- **Image:** Ubuntu 24.04, x86_64.
- **Preinstalled:**
  - Node.js 24.18.0 default, with 22.23.2 also installed (`NODE_VERSION`
    selects);
  - Go, Python and Ruby;
  - npm, yarn, pnpm, bun;
  - curl, git, unzip, zstd, build-essential, among others.
  - Rust and Flutter are not listed, hence steps 1 and 4 fetch them pinned.
- **Limits:**
  - 20-minute build timeout;
  - 8 GB memory and 20 GB disk;
  - 2 vCPU on Free, 4 on Paid;
  - 3,000 build minutes per month on Free.
- **Outbound network:** not stated. Dependency installation implies it, and
  this build relies on HTTPS to storage.googleapis.com (Flutter) and
  static.rust-lang.org (rustup and the toolchain).
- **Clone depth:** not documented. Step 2 copes either way.
- **Caching:** per the build-caching page, the cache keeps package-manager
  directories (npm's `.npm`) and a fixed list of framework output directories.
  It names no way to add a directory, so the Flutter SDK, the Rust toolchain
  and `target/` are NOT cached and are fetched or built on every deploy. The
  measured build time below includes that cost.

## Measured build time

A fresh Ubuntu 24.04 container stood in for the Free plan (2 vCPU, 8 GB),
cloned `--depth 1`, timing `npm ci` plus `npm run build`. The evidence is in
`plan/evidence/1661-vckd-observatorium-cloudflare-2026-10-13/`. The budget
agreed with the coordinator is ≤ 12 minutes of the 20-minute limit. Over that,
the plan-derived metrics (folded plan, CentiColons) ship as explicit gaps
instead, and the rest still deploys.

## Local preview

In a forge: `npm run build`, then the host-browser MCP tool `publish_local`
serves `build/web`. The preview never runs `build.command` (order 1663-6mns).
Because this app's `wrangler.jsonc` lives in `observatorium/`, not at the
repository root, publish with `app_dir: "observatorium"`. An isolated worktree
under the lane's project can instead name its own project-relative app path;
the preview must serve that worktree's `build/web`, not another checkout.

The portable `Containerfile` consumes an already-built `build/web`;
`npm run serve` is for bounded development checks.

## References (checked 2026-10-13)

- [Workers Builds: configuration](https://developers.cloudflare.com/workers/ci-cd/builds/configuration/) (Build command, Deploy command, Root directory, the Custom Builds note)
- [Workers Builds: build image](https://developers.cloudflare.com/workers/ci-cd/builds/build-image/)
- [Workers Builds: limits and pricing](https://developers.cloudflare.com/workers/ci-cd/builds/limits-and-pricing/)
- [Workers Builds: build caching](https://developers.cloudflare.com/workers/ci-cd/builds/build-caching/)
- [Workers Builds: build watch paths](https://developers.cloudflare.com/workers/ci-cd/builds/build-watch-paths/) (checked 2026-10-19: include/exclude, `*` wildcard, the 20-commit / 3000-file / zero-change bypass)
- [Workers Custom Domains](https://developers.cloudflare.com/workers/configuration/routing/custom-domains/)
- [Workers static asset configuration](https://developers.cloudflare.com/workers/static-assets/binding/)
- [Flutter release manifest (Linux)](https://storage.googleapis.com/flutter_infra_release/releases/releases_linux.json)
- [Flutter web builds and deployment](https://docs.flutter.dev/deployment/web)
