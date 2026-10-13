# Observatorium deployment

@trace spec:observatorium-dashboard

Provenance: operator request 2026-10-13; implementation verified locally with
Flutter 3.47.7, Node 22 and Wrangler 4.150.0. This supplements the dashboard spec.

The application and its tool configuration live under `observatorium/`.
Use Node 22+, Flutter 3.47.7 and the canonical `tillandsias-plan` binary built
from this checkout. From that directory:

```sh
npm ci
node scripts/history.mjs restore
npm test
flutter pub get
flutter analyze
flutter test
npx wrangler deploy --dry-run
npx wrangler deploy
node scripts/history.mjs save
```

Wrangler runs `npm run build`: collect current facts, grade residual obligations,
precompute logarithmic coordinates, then build Flutter's release artifact into
`build/web`. Set `FLUTTER` to an absolute executable path when the SDK is outside
PATH. `npm run metrics` performs only collection and precomputation.

The workflow template at `observatorium/ci/observatorium.workflow` is INACTIVE:
the forge mirror rejects any workflow filename except `release.yml`, including
the operator-authorized dashboard deployment. After the mirror allowlist is
updated, install it as `.github/workflows/observatorium.yml`. Until then there
is no automatic deployment. The template is retained as reviewable source;
it is not executed from its template location.

Once activated, the GitHub workflow runs on every main push, published release, successful
Release workflow and manual dispatch. The successful-workflow trigger covers
releases created using GitHub's built-in token, whose release events do not
trigger downstream workflows. Production source must be an ancestor of main;
successful Release runs additionally require a version tag at the source SHA.
Its repository secrets must include `CLOUDFLARE_API_TOKEN` and
`CLOUDFLARE_ACCOUNT_ID`; the token needs Workers deployment and domain/zone
permissions for the existing Cloudflare-managed `tillandsias.org` zone.
The workflow needs contents-write permission for the history research branch.
An inaccessible remote fails history restoration rather than inventing an empty
past. Only a successfully absent branch starts the first observation history.
After successful deployment, a lease-guarded push preserves the cumulative
snapshots at `research/observatorium-history` before artifact archival.

`observatorium.tillandsias.org` is an assets-only Workers Custom Domain. No
apex route is configured. Metrics revalidate after 60 seconds; index and Flutter
bootstrap revalidate on load. The app periodically fetches the precomputed
JSON; it does not rescan repository data in a browser.

Local sibling publication must use the host-browser MCP `publish_local` tool.
The portable `Containerfile` consumes an already-built `build/web` artifact;
`npm run serve` exists for bounded development checks. It does not replace the
host-managed sibling service or prove cross-device loading. In the initial
forge session, host-browser MCP was absent, the preview source selector only
recognized project-root configs, and Cloudflare authentication was absent.
Those are infrastructure gaps, not successful publication evidence.

Primary references checked 2026-10-13:

- [Flutter web builds and deployment](https://docs.flutter.dev/deployment/web)
- [Flutter web initialization](https://docs.flutter.dev/platform-integration/web/initialization)
- [Workers static asset configuration](https://developers.cloudflare.com/workers/static-assets/binding/)
- [Workers Custom Domains](https://developers.cloudflare.com/workers/configuration/routing/custom-domains/)
- [Wrangler configuration](https://developers.cloudflare.com/workers/wrangler/configuration/)
- [GitHub workflow token trigger rules](https://docs.github.com/en/actions/how-tos/write-workflows/choose-when-workflows-run/trigger-a-workflow)
