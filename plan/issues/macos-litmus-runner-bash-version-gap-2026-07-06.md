# macOS host: `scripts/run-litmus-test.sh` requires bash 4+, host ships bash 3.2 — 2026-07-06

- class: optimization (dev-loop friction)
- filed: 2026-07-06
- owner: macos
- status: ready
- trace: openspec/litmus-tests/litmus-psk-input-parity-shape.yaml (surfaced while
  authoring/validating this litmus during order 194 macOS slices 1/2/4)

## Finding

`scripts/run-litmus-test.sh` uses `declare -A` (associative arrays), a bash-4+
feature. macOS ships Apple's bash 3.2.57 (frozen pre-GPLv3) as `/bin/bash` and
this dev host has no Homebrew `bash` installed either, so every invocation of
`scripts/run-litmus-test.sh` fails immediately on macOS with:

```
scripts/run-litmus-test.sh: line 159: declare: -A: invalid option
declare: usage: declare [-afFirtx] [-p] [name[=value] ...]
```

This means no litmus test — new or existing — can be executed via the
canonical runner on a stock macOS host. Litmus authors on macOS have to hand-
verify their `critical_path` shell snippets by copy-pasting them into a
terminal (as done for `litmus:psk-input-parity-shape` this cycle) instead of
getting the runner's pass/fail + observability-log wrapper.

## Work

1. Either: change `scripts/run-litmus-test.sh` to avoid `declare -A` (portable
   bash 3.2 constructs — parallel indexed arrays or a `case`/name-mangling
   scheme instead of an associative map), so it Just Works on stock macOS; or
2. Document + automate a `brew install bash` bootstrap step (with a `#!/usr/bin/env bash`
   shebang pinned to the Homebrew path, e.g. `/opt/homebrew/bin/bash`) so the
   script opts into bash 5 explicitly rather than silently relying on
   `/bin/bash`.

Option 1 is more portable (works on a bare macOS host with no Homebrew at
all); option 2 is less invasive to the script but adds a bootstrap
dependency. Either closes the gap; whichever is picked should update
`methodology/bootstrap/router.yaml` or the macOS bootstrap doc if a new
Homebrew package becomes a hard prerequisite.

## Acceptance Evidence

- `scripts/run-litmus-test.sh <any-existing-litmus> --phase pre-build --size instant --compact`
  exits 0 (or a real pass/fail verdict, not a bash syntax error) on a stock
  macOS host with only Apple's `/bin/bash` present.
