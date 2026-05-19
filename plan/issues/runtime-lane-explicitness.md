<!-- @trace spec:environment-runtime, spec:podman-orchestration, spec:cli-mode, spec:browser-isolation-tray-integration -->

# Runtime lane explicitness and ownership

**Branch**: `linux-next`  
**Scope**: `crates/tillandsias-podman/src/lib.rs`, `crates/tillandsias-headless/src/main.rs`, `scripts/install.sh`, `scripts/uninstall.sh`, `packaging/systemd/user/tillandsias.service`  
**Status**: completed

## Why this exists

Tillandsias had the right runtime pieces, but the ownership model was implicit:

- interactive desktop launches inherited whatever Podman state the session had
- the headless installer already provisioned a dedicated service account, but the launcher did not name that lane explicitly
- dev/test wrapper state was still easy to confuse with a production runtime

The fix is to make the lane boundary explicit in code and in the durable handoff
files so future work can distinguish:

1. desktop user-session runtime
2. headless service-account runtime
3. dev/test wrapper runtime

## Current progress

- Shared runtime-lane helpers were added to `tillandsias-podman`
- Interactive launchers now preflight the desktop lane
- The headless service-account lane is validated only when service markers are present, so local dev/test runs remain usable
- Architecture and trace notes were updated to record the three lanes
- Verification completed with `cargo test -p tillandsias-podman --lib`,
  `cargo test -p tillandsias-headless --bin tillandsias --no-run`, and
  `cargo test -p tillandsias-headless --bin tillandsias`

## Reasoning preserved for future work

- Do not synthesize `/run/user/<uid>` in production
- Do not use helper wrappers in user runtime
- Do keep dev/test wrappers inside the test harness boundary
- Do keep the service-account lane explicit in packaging and supervision

## Next intended action

- Verify the compile/test pass for the launcher preflights
- Distill any new runtime failure mode into methodology/event and spec text
- Keep the plan step and issue note updated if the lane rules tighten further
