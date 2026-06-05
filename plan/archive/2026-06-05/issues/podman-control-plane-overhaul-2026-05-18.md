# podman-control-plane-overhaul — 2026-05-18

The repo now has the spine but not yet the whole nervous system.

- New work should enter through `tillandsias-podman` or
  `tillandsias-podman-cli`, never fresh shell orchestration.
- Highest-value next migration targets are `build.sh` dev-proxy lifecycle and
  `scripts/run-forge-project.sh`; both still encode Podman lifecycle policy in
  shell.
- Do not enable a repo-wide direct-call ban until those legacy callers are
  retired or explicitly grandfathered as bootstrap seams.
