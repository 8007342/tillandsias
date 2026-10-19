## MODIFIED Requirements

### Requirement: Cloudflare deployment and local artifact

Cloudflare Workers Builds SHALL deploy the app from root `observatorium` using
`npm run build` and `npx wrangler deploy`, static assets and the dashboard custom
domain. It SHALL use no GitHub Actions or Cloudflare credentials in GitHub.
The build SHALL pin downloaded toolchains by URL and SHA-256 and collect metrics
at deploy time, publishing unavailable metrics as gaps.

The Worker's only build trigger SHALL be its production branch
`refs/heads/deploy/observatorium`, with non-production branch builds off.
A stable promotion SHALL be the only automatic event that builds or deploys the
dashboard: nothing but `scripts/promote-stable.sh` (through
`scripts/advance-deploy-ref.sh`) SHALL move that branch, and the branch SHALL
only move forward. Its tip SHALL carry exactly the tree of the release the
stable channel serves.

#### Scenario: Fresh deployment runner

- WHEN Workers Builds prepares a deployment from a fresh clone
- THEN the build produces the Flutter assets and precomputed metrics
- AND the app requires no private infrastructure at rendering time.

#### Scenario: Ordinary pushes deploy nothing

- WHEN a commit is pushed to `main`, `linux-next`, a platform branch or a `work/*` ref
- THEN no observatorium build starts
- AND the deploy branch is unchanged.

#### Scenario: A demotion redeploys without a rewind

- WHEN the stable channel is demoted to an older release
- THEN `refs/heads/deploy/observatorium` advances to a restore commit whose tree is the older release's tree
- AND the previous tip is an ancestor of the new one.
