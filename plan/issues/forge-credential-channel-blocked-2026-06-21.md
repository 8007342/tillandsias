# blocked: no-credential-channel — forge container, git mirror unreachable

- class: blocker
- filed: 2026-06-21T15:27:00Z
- host: forge (TILLANDSIAS_HOST_KIND=forge)
- branch: linux-next @ 6d25a37f (clean, in sync with origin)
- status: blocked
- owner: operator (human)

## Problem

The meta-orchestration cycle ran inside the forge container and the Credential
Channel Guard (`scripts/check-credential-channel.sh`) returned
`missing:no-credential-channel` — no usable git-push credential channel exists.

Checked (all negative):
1. `.git/.gh-credentials` — file does not exist
2. `GH_TOKEN` / `GITHUB_TOKEN` — not set in environment
3. `gh auth status` — not logged in
4. Git mirror (`http://tillandsias-git:8080`) — unreachable (Connection reset)
5. Vault (`https://vault:8200`) — unreachable

## Root Cause

The git mirror service (`tillandsias-git:8080`) is not reachable from the forge
container (Connection reset by peer). This means the Option A architecture from
`forge-push-credential-channel-2026-06-20.md` (wire forge git remote to the git
mirror) cannot function — the service is down or not exposed to the forge
enclave effectively.

Without the git mirror, and without a seeded `.git/.gh-credentials` file or
`GH_TOKEN` env var, there is no path to push.

## Smallest Next Action

Re-seed the credential channel by one of:
- **Option 1**: Copy `.git/.gh-credentials` from a host-side session into the
  forge container (e.g. via `podman cp` or a bind mount from the host).
- **Option 2**: Set `GH_TOKEN` in the forge container's environment (inject at
  podman run time by the tray/launcher, or via vault injection if vault were up).
- **Option 3**: Diagnose and restart the git mirror service so it serves pushes
  from the forge enclave (longer-term fix, see
  `forge-push-credential-channel-2026-06-20.md`).

## Re-check 2026-06-22T04:57Z

Same verdict: `missing:no-credential-channel`. All channels checked:

1. `.git/.gh-credentials` — file does not exist
2. `GH_TOKEN` / `GITHUB_TOKEN` — not set
3. `gh auth status` — not logged in
4. Git mirror (`http://tillandsias-git:8080`) — returns 403 Forbidden
5. Branch `linux-next` @ `aa4050f8` — clean, 0 ahead / 0 behind

Cycle cannot proceed until a credential channel is available.

## Relation to Existing Issues

- `forge-push-credential-channel-2026-06-20.md` — architecture for wiring forge
  pushes through the git mirror; the mirror itself needs to be running.
- `cowork-headless-credential-isolation-2026-06-20.md` — the repo-local
  credential-store fix (`.git/.gh-credentials`) that resolved the Cowork
  sandbox issue; not applicable here since the file does not exist.
