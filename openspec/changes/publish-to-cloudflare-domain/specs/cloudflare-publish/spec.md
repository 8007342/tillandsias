## ADDED Requirements

### Requirement: publishing is a host act on one explicit confirmation

Connecting a project to Cloudflare SHALL happen only when the user chooses
**Publish to my domain** for that project in the tray and confirms a sheet
that names the GitHub repository, the Cloudflare account, the branch that
deploys (`main`), the custom domain, and that other branches get preview
builds. Every Cloudflare and GitHub API call it makes SHALL be made by the
host's resident process with credentials it reads from Vault. No Cloudflare
OAuth token, API token, build token or GitHub secret SHALL be written to,
mounted into, or placed in the environment or argv of a forge container,
and no forge-facing tool SHALL start a publish.

#### Scenario: cancelling the sheet makes no call

- **WHEN** the user opens Publish to my domain and chooses Cancel
- **THEN** a fake Cloudflare and a fake GitHub record no request

#### Scenario: a forge has no publish credential

- **WHEN** a project has been published and its forge is running
- **THEN** the forge's environment, mounts and argv contain no Cloudflare
  token, build token or GitHub secret, and its MCP tool list has no publish
  tool

### Requirement: the repository is connected to Workers Builds through the Builds API

On confirmation the host SHALL create (or update) the repository connection
(`PUT /accounts/{account_id}/builds/repos/connections`) and two triggers
(`POST /accounts/{account_id}/builds/triggers`): a production trigger for
`main` running the deploy command `npx wrangler deploy`, and a preview
trigger for every other branch running `npx wrangler preview`. Each uses the
project's root directory and build command, read from the project, never
guessed. A connection or trigger that already exists for the repository
SHALL be updated, not duplicated. The Tillandsias GitHub App's permissions
SHALL NOT change for this: no Secrets, Workflows or Administration
permission is requested.

#### Scenario: publishing twice leaves one connection and two triggers

- **WHEN** the user publishes the same project twice
- **THEN** the fake Cloudflare holds one repository connection and exactly
  two triggers for it

#### Scenario: the Builds scope is missing

- **WHEN** the stored Cloudflare token is refused by the Builds API (401 or
  403)
- **THEN** the sheet says which permission is missing and how to grant it
  (sign in to Cloudflare again), and nothing is created

### Requirement: the one GitHub consent is detected and handed to the browser

When the Cloudflare GitHub App is not installed on the repository's owner,
the host SHALL say so on the sheet, open the user's browser on the install
flow when the user chooses **Install Cloudflare's GitHub App**, and continue
the publish only after the installation is visible to the Builds API. It
SHALL NOT attempt the installation itself and SHALL NOT ask for the user's
GitHub credentials.

#### Scenario: a second project under the same account asks for nothing

- **WHEN** a second repository under a GitHub account that already has the
  Cloudflare GitHub App installed for all repositories is published
- **THEN** no browser step is offered, and the publish completes on the
  confirm alone

### Requirement: the custom domain comes from the project and is preflighted

The custom domain SHALL be the project's own wrangler configuration
(`routes` entries with `custom_domain = true`). Before connecting anything,
the host SHALL check that each such hostname belongs to a zone in the
user's Cloudflare account and that the hostname has no CNAME record. It
SHALL refuse with the hostname and the reason (`zone-not-in-account`,
`cname-exists`, `no-custom-domain-declared`) rather than create, change or
delete DNS records itself.

#### Scenario: a domain outside the account is refused by name

- **WHEN** the project declares `app.example.com` and no zone `example.com`
  exists in the user's account
- **THEN** the publish refuses with `zone-not-in-account:app.example.com`
  and creates no connection

### Requirement: the build's outcome and its reason are visible host-side

After a publish, and after each push the host relays for that project, the
tray SHALL show the latest build's state (building, deployed, failed) and,
for a failed build, the reason read from the build's logs
(`GET /accounts/{account_id}/builds/builds/{build_uuid}/logs`). It SHALL also
show the measured time from the push to the build's completion. How the state
is obtained SHALL follow an explicit ruling on the project's no-polling rule.
Until that ruling exists, the tray shows "pushed; Cloudflare is building" and
the live URL, and makes no repeated request.

#### Scenario: a failed preview build shows its reason

- **WHEN** a preview build fails in the fake Cloudflare with the log line
  "Missing entry-point"
- **THEN** the project's menu shows the failure with that reason

### Requirement: the host-side deploy fallback runs outside every forge

If the Workers Builds connection cannot be created without a dashboard step
the operator declines, publishing SHALL instead run `wrangler deploy` on the
host's behalf after the project's push, in a sibling container that is not
a forge (no agent runs in it), from the `web-wrangler` image. The
short-lived access token SHALL reach it only as a file on a tmpfs mount
removed when the deploy ends, never in its environment or argv. The tray
SHALL say that this mode deploys only pushes made through Tillandsias.

#### Scenario: the fallback's token never outlives the deploy

- **WHEN** a fallback deploy finishes or fails
- **THEN** the sibling container and its token mount no longer exist, and
  the token never appeared in its environment or argv
