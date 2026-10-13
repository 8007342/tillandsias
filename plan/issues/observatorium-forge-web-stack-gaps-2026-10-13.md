<!-- @trace spec:observatorium-dashboard -->

# Observatorium forge web stack gaps

order: 1662-tff5
status: ready

Observed in the 2026-10-13 forge session implementing 1661-vckd.

The forge introduction claims Flutter is available on PATH, but `flutter
--version` exits 127. Cached Dart is present. Sol is provisioning a temporary
Flutter SDK to attempt validation. The bootstrap claim is false on this image;
Flutter projects cannot exercise the documented full stack without provisioning.

The startup context prescribes host-browser `publish_local` for managed sibling
web publication. No publish_local, service_status, browser.open or device-browser
tool is exposed in this session's tool catalog. Podman/docker are also absent.
Consequently neither a managed sibling container nor device dogfooding can be
claimed from this forge. The app includes a portable built-artifact Containerfile
and a development-only artifact server, which do not establish managed hosting.

Terra additionally verified the local preview detector in
`crates/tillandsias-headless/src/local_web_preview.rs`: Wrangler detection checks
root configuration (around line 342), and static detection checks root
`var/html`, `public`, `dist` or `index.html` (around line 832). The requested
self-contained app at `observatorium/wrangler.jsonc` and
`observatorium/build/web` needs explicit subdirectory selection. Adding a root
wrapper config would violate the operator's isolation intent and obscure this
missing capability.

`npx wrangler whoami` reports unauthenticated, and no CLOUDFLARE deployment
environment variables are present. Production publication is unverified; the CI
workflow expects repository secrets CLOUDFLARE_API_TOKEN and CLOUDFLARE_ACCOUNT_ID.
This credential dependency is separate from the missing local hosting tools.

Smallest fixes / exit criteria:

- Correct the forge Flutter availability claim or ship an executable SDK;
  demonstrate `flutter --version` in a fresh forge and build this app.
- Expose the managed sibling publish and device-browser MCP tools to this harness.
- Add an explicit app directory/build artifact selector to publish_local, confined
  to the calling project's checkout; test nested observatorium configuration.
- Publish the built dashboard through that service and open it in representative
  desktop and phone presets, recording actual observations and engine identity.
- Supply scoped Cloudflare credentials through existing secrets infrastructure and
  verify the custom domain deployment without revealing credential values.

Root cause: image/tool exposure and root-only project detection do not yet match
the documented nested web app dogfooding contract. Keep limitations explicit until
live evidence exists. This packet does not authorize tray UX changes.

Additional integration observations and disposition:

- The first commit failed with `Author identity unknown`. A repository-local
  agent identity (`Codex Observatorium <codex-observatorium@localhost>`) allowed
  the checkpoint; the forge's transparent Git bootstrap does not seed identity
  for this harness. Exit criterion: a fresh authenticated forge can commit with
  an explicitly attributed identity without impersonating the operator.
- The full gate stalled in `check-all-fragments-intact.lua`: its policy facade
  launched Cargo without the forge's CARGO_HOME/CARGO_TARGET_DIR, matching
  existing packet `1593-1ny6`. No compiler child ran; Cargo waited with the
  default `/home/forge/.cargo/.package-cache` open. Building the policy binary
  in the configured cache and copying it into ignored `target/debug/` avoids
  the fallback locally. Terminating the stalled Cargo produced a false claim
  that all 4,368 YAML files were damaged; this is a validator execution failure,
  not evidence of corrupt ledger files. Revalidation is required.
- The full gate then exposed a real app integration problem:
  `crates/tillandsias-headless/build.rs` recursively embeds `observatorium/` and
  panics on `observatorium/node_modules/.bin/cf-wrangler`. Even without symlinks,
  recursive inclusion would package development dependencies and generated public
  artifacts into the host runtime. The fix restricts that embedded asset boundary
  to the four existing private trace-viewer assets. Public Flutter output remains
  its own deployment. Exit criterion: a populated npm/Flutter worktree passes the
  host build and embedded legacy viewer assets remain intact.
