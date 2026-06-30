# Issue: `tillandsias --init` fails due to cargo-binstall 403 Forbidden on GitHub API

During the execution of the `/smoke-curl-install-and-test-e2e` skill for release `v0.3.260612.3`, the `tillandsias --init` step failed to reach a healthy state. The `forge` image build halted with `exit status: 94`.

## Details
The root cause is `cargo-binstall` hitting GitHub API rate limits (403 Forbidden) and subsequently timing out when attempting to resolve and download crates such as `cargo-audit`, `cargo-edit`, `cargo-chef`, `cargo-criterion`, etc.

**Snippet from `target/smoke-e2e/03-init.log`:**
```text
[tillandsias] build-forge:  INFO has_release_artifact{release=GhRelease { repo: GhRepo { owner: "killercup", repo: "cargo-edit" }, tag: "v0.13.11" } ...}: Received status code 403 Forbidden, will wait for 120s and retry
...
[tillandsias] build-forge:  WARN resolve: Timeout reached while checking fetcher QuickInstall: deadline has elapsed
[tillandsias] build-forge: ERROR Fatal error:
[tillandsias] build-forge:   × For crate cargo-audit: Fallback to cargo-install is disabled
[tillandsias] build-forge:   ╰─▶ Fallback to cargo-install is disabled
[tillandsias] build-forge: Error: building at STEP ... exit status 94
```

## Impact
The smoke test could not proceed to Step 4 (Forge continuous enhancement) as the enclave failed to initialize successfully from a pristine state.

## Proposed Action
- Future `/advance-work-from-plan` workers should investigate a way to avoid GitHub API rate-limiting during `cargo binstall` in the `Containerfile` build of the `forge` image. This could be achieved by ensuring a `GITHUB_TOKEN` is reliably passed, switching to native `cargo install`, or migrating to `dnf` packages where possible.
