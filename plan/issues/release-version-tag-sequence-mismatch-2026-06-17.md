# Release Version Tag Sequence Mismatch - 2026-06-17

Discovered during `/meta-orchestration` release pre-flight after pushing
`linux-next` to `8f989150`.

## Work Packet: release/version-tag-sequence-mismatch

- id: `release/version-tag-sequence-mismatch`
- owner_host: linux
- capability_tags: [release, git, versioning, coordination]
- status: claimed
- severity: high - blocks `/merge-to-main-and-release` from cutting the next
  release without either downgrading `VERSION` on `main` or publishing a tag
  sequence that skips `v0.3.260617.1`.
- discovered_by: `/meta-orchestration` on mutable Linux
- blocker: release policy decision required
- smallest_next_action: >
    Decide whether today's release should use `v0.3.260617.2` to match the
    accepted local-build evidence, or whether `linux-next` should be reset to
    `VERSION=0.3.260617.1` and re-tested before release. If choosing the first
    option, update `/merge-to-main-and-release` guidance to avoid downgrading
    `main` when the current `VERSION` already has today's date and is greater
    than the tag-derived next sequence.
- lease:
    lease_id: "lease-linux-v-tag-mismatch-20260617T2220"
    agent_id: "linux-tillandsias-gemini-cli-2026-06-17T2220Z"
    host: "linux"
    acquired_at: "2026-06-17T22:20:00Z"
    expires_at: "2026-06-18T02:20:00Z"
- evidence:
  - `VERSION` at `origin/linux-next@8f989150` is `0.3.260617.2`.
  - The accepted local build/install smoke also reported
    `Tillandsias v0.3.260617.2`.
  - `git ls-remote --tags origin 'refs/tags/v0.3.260617.*'` returned no tags.
  - The literal `/merge-to-main-and-release` tag formula would compute
    `v0.3.260617.1` from the empty remote tag set.
  - Merging `linux-next` to `main` first would bring `VERSION=0.3.260617.2`;
    then the release step would write `VERSION=0.3.260617.1` on `main`, which
    is a downgrade relative to both `linux-next` and the smoke evidence.
- safe_stop: >
    No release PR, tag, or workflow_dispatch was started from this cycle.

## Events

- type: claim
  ts: "2026-06-17T22:20:00Z"
  agent_id: "linux-tillandsias-gemini-cli-2026-06-17T2220Z"
  host: "linux"
  lease_id: "lease-linux-v-tag-mismatch-20260617T2220"
  expires_at: "2026-06-18T02:20:00Z"

- type: discovered
  ts: "2026-06-17T21:48:45Z"
  agent_id: "linux-tlatoani-codex-meta-orchestration"
  host: linux
  note: >
    Pre-flight was otherwise releasable: checkout was on clean `linux-next`,
    `origin/linux-next..HEAD` was 0 after push, there was no open
    `linux-next -> main` PR, and recent `release.yml` runs had no queued or
    running release. Release was stopped only because the next tag policy and
    current `VERSION` disagree.
