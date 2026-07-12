# "stable" release channel: label + README install scripts pinned to stable

- Date: 2026-07-12
- Class: enhancement (work packet — order 305)
- Filed by: linux_mutable meta-orchestration cycle (operator directive)
- Status: ready (design + implement when claimed; not urgent, operator said
  "soon")

## Operator directive (2026-07-12)

We are approaching a point where a release should be labeled **stable** and
the curl-install scripts referenced from the README should point at the
"stable" release, while daily CalVer releases keep shipping breaking changes
on the side.

## Current state

- 0.3.x CalVer dailies via /merge-to-main-and-release; GitHub "latest release"
  is whatever shipped last.
- README install scripts curl the latest release asset — every daily,
  breaking or not, immediately becomes what new users install.

## Sketch

1. Introduce a `stable` release label/tag (e.g. a moving `stable` tag or a
   GitHub release marked latest while dailies are marked pre-release).
2. README curl-install scripts resolve the `stable` label, not
   `releases/latest` semantics that dailies clobber.
3. Promotion is an explicit operator (Tlatoāni) action — a small script or
   workflow_dispatch that retags/promotes a vetted daily to stable, gated on
   curl-install e2e PASS evidence in plan/.
4. plan/loop_status.md records both `latest` and `stable` so hosts know which
   release curl-install e2e should exercise.

## Exit criteria

- A promoted release is downloadable via a stable-pinned URL that does not
  move when a daily ships.
- README install instructions use the stable URL; dailies are marked
  pre-release (or otherwise excluded from the stable resolution path).
- Promotion procedure documented in methodology/versioning.yaml with the
  e2e-evidence gate.
- Verifiable closure: a litmus/shape test asserting the README install URL
  resolves the stable channel and that release automation marks dailies
  pre-release.
