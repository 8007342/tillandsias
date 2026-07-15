# Malformed GitHub release tag `vv0.3.260626.3` (double-v)

- Date: 2026-07-15
- Class: optimization
- discovered_by: scripts/resolve-smoke-release.sh (order 367) — a raw
  `gh api releases | .[0]` returned this junk tag first.

## Observation

The repo has a release tagged `vv0.3.260626.3` (double `v`), from ~June.
It does not match the canonical daily/stable grammar `v#.#.#.#` and sorted
ahead of real releases by naive API order, which would have pointed the
curl-install smoke at a stale/malformed artifact. The resolver now filters
to the canonical grammar (`sort -V | tail -1`), so this no longer misleads
smoke — but the junk release still exists.

## Smallest next action

Delete or retag the `vv0.3.260626.3` release/tag (operator decision — it may
carry assets someone linked). Investigate how a double-`v` tag was created
(a release script that prefixed `v` onto an already-`v`-prefixed VERSION?)
and pin the release tag grammar in the release workflow so it can't recur.
