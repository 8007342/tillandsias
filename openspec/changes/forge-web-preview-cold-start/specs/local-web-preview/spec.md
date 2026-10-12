## ADDED Requirements

### Requirement: Managed preview runtime images materialize without agent action

Every runtime profile that `publish_local` can select (`static`, `wrangler`,
and `auto`'s resolution of either) MUST have its managed image built
host-side by the product. Initialization MUST build it, or the host MUST build
it on the first publish that needs it, within a stated bound. A publish MUST
NOT refuse with a precondition that only an operator or a host command could
satisfy. The image name a publish probes MUST be the name initialization tags.
The build MUST take no image name, path, command or argument from the agent.

> Delta: on 2026-10-12 a cold-start forge got "initialize the managed runtime
> image before publication" for `auto` and `wrangler` on every retry. No code
> path built `tillandsias-web-wrangler` (packet 1625-un54).

#### Scenario: First Wrangler publish on a fresh host
- **GIVEN** a freshly provisioned host where the Wrangler preview image does not exist
- **WHEN** a forge agent calls `publish_local` with `runtime` `wrangler` (or `auto` on a project with one root Wrangler configuration)
- **THEN** the host builds the image and the call returns a preview URL
- **AND** the agent supplied nothing beyond the existing MCP arguments

### Requirement: Publish failures name their step

A failed `publish_local`, `service_reload` or `service_stop` MUST return a
stable reason code that names the failed step and its class. Steps are
container listing, inspection, image, source mounts, router, run and
readiness; classes are transport, exit, timeout and absent. Raw podman
output MUST stay withheld, because it can carry project secrets. After a
failed publish, `service_status` MUST report the last failure for that
project: step, reason code, time, and whether a host-side retry or an
operator action can remedy it.

> Delta: on 2026-10-12 `runtime` `static` failed with "Podman operation
> failed", and `service_status` was empty. The agent could not tell an absent
> image from a down podman or a failed router (packet 1625-6iwd).

#### Scenario: Distinct reasons per step
- **WHEN** podman fails at container listing, inspection, image check, run, or router start
- **THEN** each failure yields a different reason code naming its step
- **AND** none of them contains podman's raw output

#### Scenario: Status after a failed publish
- **GIVEN** a publish that failed
- **WHEN** the agent calls `service_status`
- **THEN** the response reports that failure's step, reason code and time, and who can remedy it

### Requirement: Static source selection names what it looked for

The `static` profile MUST serve a root Wrangler configuration's
`assets.directory` when one is configured, ahead of the fixed `var/html`,
`public` and `dist` list. When nothing servable exists, the publish MUST fail as
a source-selection failure (step source, class absent) that names the paths it
looked at, never as a runtime or podman error. When the configured assets
directory is absent, the failure MUST say so, name the directory and the
configuration file, and name the declared `build.command` (by key alone when it
could carry a credential), so the agent knows to build first. The same holds for
the `wrangler` profile's assets directory. Raw configuration content MUST NOT
reach the response.

> Delta: on 2026-10-12 visual-chess (`assets.directory` `./dist`, dist/ not yet
> built, no root `index.html`) failed `static` with "Podman operation failed".
> The root `index.html` probe (`realpath -e`) exits 1 when the file is absent
> (packet 1625-6iwd).

#### Scenario: No servable root
- **GIVEN** a project with no `var/html`, `public`, `dist` or root `index.html`, and no root Wrangler configuration
- **WHEN** the agent publishes with `runtime` `static`
- **THEN** the reason is `source_not_found` and names `var/html`, `public`, `dist` and `index.html`

#### Scenario: Configured assets directory not built yet
- **GIVEN** a root `wrangler.jsonc` whose `assets.directory` is `./dist`, and no `dist/`
- **WHEN** the agent publishes with `runtime` `static`, `auto` or `wrangler`
- **THEN** the reason is `source_not_found`, names `dist` and `wrangler.jsonc`, and says to build the project first

#### Scenario: Static honors assets.directory
- **GIVEN** a root Wrangler configuration whose `assets.directory` is `./www`, with `www/` present
- **WHEN** the agent publishes with `runtime` `static`
- **THEN** `www/` is what the static runtime serves

### Requirement: Cold-start web preview acceptance

On a freshly installed host, a forge given only "serve this web project
locally" for a project that builds to static assets (including a Wrangler +
wasm project) MUST be able to build the assets in the forge, publish them
through `host-browser`, and return a URL that the host browser loads through
the router. No operator step is allowed between install and load.

#### Scenario: Wrangler + wasm fixture, no operator
- **GIVEN** a freshly installed host and a forge on a Wrangler + wasm fixture project
- **WHEN** the agent is asked only to serve the project locally
- **THEN** an HTTPS fetch of the URL `publish_local` returns yields the fixture's page
- **AND** no operator action occurred
