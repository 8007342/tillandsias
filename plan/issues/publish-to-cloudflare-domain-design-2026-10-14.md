# Design: push to remote, and the project is live on the user's own Cloudflare domain (1707-g633)

Order 1707-g633. Status: **recommendation, awaiting the operator's acceptance.**
Filed from the operator's prompt-to-app direction (2026-10-14): "buy a domain on
cloudflare and create a new project on github ... then just 'push to remote'
should let CloudFlare take care of the rest." Spec deltas:
`openspec/changes/publish-to-cloudflare-domain/`.

## The recommendation in one paragraph

Use **Cloudflare Workers Builds**, connected to the user's GitHub repository by
**Tillandsias's host side**, through Cloudflare's public Builds API, on **one
explicit "Publish to my domain" click** in the tray. Cloudflare builds and
deploys on every push to `main`, and branch pushes get preview builds. The
custom domain comes from the project's own wrangler config
(`custom_domain = true`). No Cloudflare credential, build token or GitHub secret
ever enters a forge, and nothing new is stored in GitHub. The user needs **one
browser consent per GitHub account, ever**: installing the Cloudflare GitHub
App, which no API can do. Cloudflare's GitHub integration requires it ("you
must first install the Cloudflare GitHub App through the dashboard"). Two facts
are not yet known and **decide whether the click needs zero more dashboard
steps or one**. They must be measured before the first slice (see "Spike
first"). If either fails, the fallback is a **host-side deploy**, not GitHub
Actions.

## What was measured, and what was read

| Fact | Kind | Source |
|---|---|---|
| macron.dev push → Workers Builds check complete, `main`: 12m37s, 1m31s, 59s, 6m46s (all success) | measured 2026-10-14 by the macron.dev forge agent, from GitHub check runs | `plan/issues/e2e-smoke-v56.10.14.1-macos-2026-10-14.md`; macron.dev `/deploys/log.jsonl` |
| macron.dev branch builds 9m39s and ~27s, both FAILED, with no reason shown in the check run | measured, same | same |
| The observatorium's Workers Builds connection was wired by hand in the dashboard (repo, branch, root dir, build command, custom domain) | read | `openspec/specs/observatorium-dashboard/deployment.md` |
| Workers Builds image: Ubuntu 24.04 x86_64, no Rust or Flutter, cache keeps only package-manager and framework dirs, 20-min limit, 1 concurrent build on Free | read, 2026-10-13 | same, Cloudflare docs |
| `--cloudflare-login` is PKCE against the project's own registered Cloudflare App; `CLOUDFLARE_LOGIN_SCOPES` is **empty** until the operator records the scope ids the consent screen lists; tokens live at `secret/cloudflare/{token,refresh}`, read only by the host's resident process | read | `crates/tillandsias-headless/src/cloudflare_login.rs:68-72`; `openspec/changes/cloudflare-login-and-fleet-vpn/design.md` Decision 2 |
| Forges hold zero credentials: "No AppRole value, Vault token, GitHub token ... SHALL cross into a forge container" | read | `openspec/specs/git-mirror-service/spec.md`; `openspec/specs/forge-offline/spec.md` |
| A forge's push leaves through the host mirror with a short-lived GitHub App installation token scoped `{contents: write}` | read | `plan/issues/github-app-fine-grained-interaction-research-2026-07-31.md` §6.3 |
| Workers Builds has a public API: `PUT /accounts/{id}/builds/repos/connections`, `POST /accounts/{id}/builds/triggers` (build/deploy command, root dir, branch includes/excludes), build logs, manual builds; needs **Workers Builds Configuration: Edit** + Workers Scripts: Read, on a **user**-scoped token | read, Cloudflare docs updated 2026-09-22 | developers.cloudflare.com/workers/ci-cd/builds/api-reference/ |
| Build-token creation (`POST /builds/tokens`) exists but its request body is **undocumented** | read | same |
| Whether the Builds API accepts an **OAuth** token at all is **undocumented** | read | same |
| `wrangler login`'s default scopes include `workers_scripts:write`, `workers_routes:write`, `zone:read`, but **not** `workers_builds:write` and nothing that creates API tokens; `workers_builds:write` appears only in Cloudflare's own `cf` client registration | read, wrangler source `packages/workers-auth/src/core/scopes.ts` @ a0712e5 | github.com/cloudflare/workers-sdk |
| Custom domain: `PUT /accounts/{id}/workers/domains` (needs Workers Scripts Write), or `routes = [{ pattern = "example.com", custom_domain = true }]`; Cloudflare creates the DNS record and certificate; refuses a hostname that has a CNAME, or a zone the caller doesn't own | read, docs 2026-09-29 | developers.cloudflare.com/workers/configuration/routing/custom-domains/ |
| Preview builds: a second trigger (`branch_includes ["*"]`, excluding `main`, deploy command `npx wrangler preview`, Wrangler ≥ 4.135.0) | read, docs 2026-09-24 | developers.cloudflare.com/workers/previews/ |

The Cloudflare API facts were gathered by a research subagent on 2026-10-14 from
the cited pages. They're **read, not exercised**: no Cloudflare write API was
called.

## The options

### A. Workers Builds, connected by the host on one click (RECOMMENDED)

The user clicks **Publish to my domain**, confirms, and then the host:
1. checks the Cloudflare GitHub App is installed on the repo's owner; if not,
   opens the browser on the install page and waits (the only browser step, once
   per GitHub account);
2. creates the repo connection and two triggers: production (`main`,
   `npx wrangler deploy`) and preview (`*` except `main`, `npx wrangler
   preview`), with the root directory and build command read from the project;
3. checks the custom domain in the project's wrangler config is a zone in the
   user's account with no CNAME at that name, and refuses by name otherwise;
4. starts the first build and shows its state in the tray.

| | |
|---|---|
| User steps | one confirm click; plus the GitHub App install, **once per GitHub account** |
| Credential exposure | none new: the host uses its Vault OAuth token, nothing in GitHub, nothing in a forge |
| GitHub App permission change for Tillandsias | **none** (the mirror token stays `{contents: write}`) |
| Builds happen when the user's machine is off | **yes**, which is what "Cloudflare takes care of the rest" means |
| Branch previews | yes (second trigger) |
| Deploy latency | 59 s to 12m37s measured; queues behind other builds on Free (1 concurrent); Flutter is fetched on every build (not cached) |
| Unknowns | U1: can the project's Cloudflare App request `workers_builds:write` (and Workers Scripts read), and does the Builds API accept its OAuth token? U2: can the host create the build token the trigger needs by API? |

### B. GitHub Actions + a Cloudflare API token as a repo secret (NOT recommended)

Commit a workflow (`cloudflare/wrangler-action`), mint a Cloudflare API token
and store it as `CLOUDFLARE_API_TOKEN`.

| | |
|---|---|
| User steps | the same unknown as U1, made harder: minting a token needs `account_api_tokens:create` (or the "Create additional tokens" template), which no documented third-party scope offers, so in practice it's **a dashboard step** |
| Credential exposure | a **long-lived Cloudflare token stored in GitHub**, outside our Vault, with its own rotation and revocation burden |
| GitHub App permission change | **Secrets: write** (`PUT /repos/{o}/{r}/actions/secrets/{name}`) and **Workflows: write**. A forge-committed `.github/workflows/*` file can't even be pushed through the mirror's `{contents: write}` token. GitHub makes every existing installation re-approve a permission change, and until then installations keep the old permissions (research note §2.3) |
| Builds when the machine is off | yes |
| Advantage | GitHub runners can cache Flutter (`actions/cache`), so builds could be faster than option A's uncached ones |

B costs a permission expansion on the App every user has installed, plus a
long-lived secret in a third party. Even then it doesn't remove the token-minting
step. That's why it's rejected.

### C. Host-side deploy after the push (FALLBACK)

After the mirror push, the host runs `wrangler deploy` in a sibling container
(the existing `images/web-wrangler`; **not a forge**: no agent runs in it), with a
short-lived access token handed to it as a tmpfs file, never in env
(`podman-idiomatic-patterns.invariant.secrets-not-in-env`).

| | |
|---|---|
| User steps | one confirm click; no GitHub consent, no dashboard |
| Scopes needed | only standard wrangler scopes (`workers_scripts:write`, `workers_routes:write`, `zone:read`), so it has no dependency on U1 or U2 |
| Builds when the machine is off | **no**: a push from another machine, or an edit on github.com, doesn't deploy. That's the gap against the operator's wording |
| Deploy latency | the user's machine builds, so it's as fast as the forge's own `flutter build web` (seconds to a minute here), with no queue |
| Credential exposure | a short-lived token in a non-forge sibling container, for the length of one deploy. That's a new class of container and needs its own spec requirement |

C is the fallback if U1 or U2 fails. It's also the right **interim** if the
operator wants publishing working before the Cloudflare unknowns are measured.

## Spike first (before the first slice)

Two measurements decide between A and C. Both need the operator, because
they act on the operator's Cloudflare account:
1. **U1 (scopes).** When registering the project's Cloudflare App, record
   whether `workers_builds:write` (or the consent screen's equivalent) is
   offered to a third-party client. If it is, add it to
   `CLOUDFLARE_LOGIN_SCOPES` with the exact id. Then call `GET
   /accounts/{id}/builds/triggers` (read-only) with the stored OAuth token. A
   200 settles U1; a 401/403 names the gap.
2. **U2 (build token).** On a throwaway Worker, create a build token by API.
   If the body is undocumented and the call can't be made to work, A needs **one
   dashboard step** (Settings → Builds → API token) per Cloudflare account, and
   the operator decides whether that's acceptable or C ships instead.

## The branch builds that failed today

The macron.dev branch builds failed with no reason in the check run. With
option A the host can read `GET /builds/builds/{uuid}/logs` and show the
reason. The first slice should do exactly that for the macron.dev failures
before it changes anything. The documented causes are a Worker name that
differs from the config, a missing config at the root dir, an `account_id`
for another account, a deleted build token, or a timeout. Preview builds also
need their own trigger with `npx wrangler preview` (Wrangler ≥ 4.135.0). A
non-production trigger left on the default deploy command is the leading
guess, not yet verified.

## Deploy-time visibility, and the no-polling rule

Push → live took from 59 s to 12m37s, so the tray should show "building ·
deployed · failed (why)", plus the measured push → live time. Cloudflare can't
call into the enclave, and Tillandsias forbids polling in favour of event
streams (memory and methodology). The GitHub App research note §5.3 already
recommends **outbound conditional requests (ETag), no listener** for GitHub
events. This design proposes the same for the build state: one conditional
`GET` per build, backed off, ending when the build ends. **This needs the
operator's or coordinator's explicit ruling** against the no-polling rule
before the slice. The alternative is to show only "pushed, Cloudflare is
building (usually 1-13 min)" and let the user open the URL.

## What the user sees

Tray, on a project whose wrangler config names a custom domain:
**Publish to my domain…** → a confirm sheet naming exactly what will happen
("Connect github.com/<owner>/<repo> to Cloudflare Workers Builds in account
<name>; build `main` on every push; serve it at <domain>; preview other
branches") → [Publish] / [Cancel]. If the Cloudflare GitHub App is missing, the
sheet says so and the button reads **Install Cloudflare's GitHub App** (opens
the browser), then resumes. After publishing, the project's menu shows the live
URL and the last build's state and time. A forge agent gets none of this. Its
part ends at `git push`, and it can't read the deploy status unless 1715-xp6x
lets it GET its own domain.

## Questions from the row, answered

1. *Fewest user steps without a credential in a forge?* A: one click, plus one
   GitHub App consent per GitHub account, provided U1 and U2 hold. Otherwise C:
   one click.
2. *Can the host create the Workers Builds connection, or set the GitHub
   secret, on an explicit click?* The connection: yes, by documented API, if U1
   holds. The secret: only with new Tillandsias App permissions (Secrets and
   Workflows: write) and a token-creation scope, so no.
3. *How does a domain already in the account become the custom domain?* From
   the project's wrangler config (`custom_domain = true`), applied by the
   deploy itself, with a host-side preflight that the zone exists in the
   account and the name has no CNAME, or by `PUT /workers/domains`.
4. *What does the user see?* One tray action with a confirm sheet, above.

## Out of scope

Buying the domain (the user does it at Cloudflare). Creating the GitHub repo
(prompt-to-app's onboarding skill, 1705-bgen). Forge egress to the deployed
site (1715-xp6x). Caching Flutter in Workers Builds (Cloudflare's cache list
has no hook; a separate row if build time matters).
