# Proposal — publish-to-cloudflare-domain

Order `1707-g633` (design row, desired_release v0.6). Design record:
`plan/issues/publish-to-cloudflare-domain-design-2026-10-14.md`. Status:
**awaiting the operator's acceptance**; nothing here is implemented.

## Why

The operator's prompt-to-app direction (2026-10-14): "buy a domain on
cloudflare and create a new project on github ... then just 'push to remote'
should let CloudFlare take care of the rest." Today the last step is manual:
the observatorium's Workers Builds connection (repo, branch, root directory,
build command, custom domain) was wired by hand in the Cloudflare dashboard
(`openspec/specs/observatorium-dashboard/deployment.md`), and macron.dev's
branch builds fail in Cloudflare with no reason a forge or the tray can see.

## What changes

- A new capability, `cloudflare-publish`: one tray action, **Publish to my
  domain**, on an explicit confirm, through which the HOST connects the
  project's GitHub repository to Cloudflare Workers Builds (a production
  trigger for `main`, a preview trigger for other branches) using the user's
  Cloudflare OAuth token from Vault. The custom domain comes from the
  project's own wrangler config, preflighted by the host.
- The one consent no API can perform, installing the Cloudflare GitHub App
  on the repository owner, is detected and handed to the user's browser,
  once per GitHub account.
- The build's state and its failure reason (from the Builds logs API) are
  shown host-side. Forges get nothing new.
- A fallback, used only if the two measured unknowns below fail: a host-side
  `wrangler deploy` in a non-forge sibling container with a short-lived
  token handed over as a file.

## What does not change

- No Cloudflare credential, build token or GitHub secret enters a forge
  (`git-mirror-service`, `forge-offline`).
- The Tillandsias GitHub App's permissions are unchanged: the mirror token
  stays `{contents: write}`. No Secrets or Workflows permission is added, so
  no installation has to re-approve.
- Nothing new is stored in GitHub.

## Decided by measurement before the first slice

- **U1**: can the project's registered Cloudflare App request the Workers
  Builds scope, and does the Builds API accept its OAuth token? (Wrangler's
  default scopes don't include `workers_builds:write`, and Cloudflare's docs
  don't say whether OAuth tokens are accepted.)
- **U2**: can the host create the trigger's build token by API? (The endpoint
  exists; its request body is undocumented.)

If either fails, the operator chooses between one dashboard step per
Cloudflare account, and the host-side deploy fallback.

## Needs a ruling before the slice

Showing build progress means asking Cloudflare for the build's state. The
design proposes one conditional request per build, ended when the build
ends, the same posture as the GitHub App research note §5.3. That has to be
reconciled with the project's no-polling rule explicitly.
