<!-- @trace spec:observatorium-dashboard -->

# Observatorium forge web stack gaps

order: 1662-tff5
status: ready

Durability blocker discovered after implementation: the mirror's server-side
pre-receive rejects `.github/workflows/observatorium.yml` with
`is not an allowed CI workflow; allowed: release.yml`, despite the operator's
explicit auto-deployment request and the corresponding local policy amendment.
The implementation retains that workflow as the INACTIVE source template
`observatorium/ci/observatorium.workflow` so the app and findings can be pushed
without bypassing the hook. No automatic deployment exists until the mirror
allowlist is amended and the template installed at its intended workflow path.
Exit criterion: the mirror accepts that explicitly authorized workflow, while
still rejecting unrelated CI files, and a main push deploys the dashboard.

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
- The workspace tmpfs is only 692 MiB (`df -h`), despite the startup hardware
  report describing 8 GiB RAM. npm dependencies (229 MiB) and Flutter generated
  builds (93 MiB) exhausted it during the full gate's archive-refusal fixture
  copy. The gate printed `could-not-run:append-event-archived-refusal:scratch-copy-failed`
  and then incorrectly described a behavioral regression. Moving these ignored
  generated directories to `~/.cache/tillandsias/observatorium-generated/` with
  local symlinks restored space; this touches only the forge's ephemeral cache.
  Exit criterion: provision sufficient workspace capacity or route generated web
  artifacts to the ephemeral cache by default, and distinguish fixture resource
  failure from a tested archive-guard regression. No host disk was accessed.
- On the resumed full gate, the separate 20 GiB forge filesystem filled during
  workspace test linking (`ld.bfd: final link failed: No space left on device`;
  `tillandsias-logging` test `event_coverage`). Cargo target storage reached
  18 GiB, including 6.6 GiB of incremental state and 9.3 GiB of debug dependencies.
  The app and findings were already durably pushed at `work/1661-vckd@5744b13a9`.
  Removing disposable incremental state recovered 4.8 GiB of actual free space.
  The retry disables incremental compilation and debug symbols for dev/test
  profiles; these options preserve the checks and test assertions. Exit criterion:
  a fresh forge can complete the mandatory full gate within its provisioned
  storage, or refuses early with a capacity diagnosis rather than exhausting disk.
- With storage pressure resolved, all 3,045 workspace tests passed, but the
  tray/listen-vsock suite failed two newly merged browser argv tests:
  `browser_open::tests::window_spec_joins_only_its_network_and_pins_the_ca` and
  `browser_open::tests::webkit_window_spec_is_confined_like_the_chromium_window`.
  Both constructed a display context rooted at `/run/user/1000` and unwrapped
  the production constructor, which correctly refuses the nonexistent host
  `wayland-0` socket in a headless forge. Repro: `cargo test -p
  tillandsias-headless --bin tillandsias --features tray,listen-vsock
  browser_open::tests:: -- --test-threads=1`. The tests now own a temporary
  display directory and socket (a path fixture on non-Unix); production Wayland
  validation is unchanged. The WebKit assertions use that actual fixture path
  and still reject mounting the whole runtime directory. Exit criterion: both
  confinement tests pass in a headless forge without a user compositor.
- The next run passed all workspace and feature-gated tests, then filled the
  692 MiB tmpfs again: `target/archive-answerability/tree` retained a 321 MiB
  checkout copy, leaving no room for the later dialect fixture's tiny script.
  The existing `TILLANDSIAS_ARCHIVE_CHECK_WORK` override allows this transient
  copy to live in the forge cache. The retry uses
  `~/.cache/tillandsias/observatorium-archive-answerability` without changing
  the tested ledger or assertions. Exit criterion: mandatory gates select an
  adequately sized scratch root for tmpfs forges by default, as they already
  select native storage for 9P checkouts.
