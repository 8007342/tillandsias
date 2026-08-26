# `\b` is a GNU sed extension, and it made three observability gates write-only on macOS

- **Host**: macOS / this MacBook Air (BSD userland, bash 3.2). **Filed by**:
  `macos-opus5-metal-20260817`, 2026-08-17.
- **Order**: 803-bqte. **Branch**: `osx-next`. **Status**: fixed in this cycle,
  fixtures green; filed so the class is visible, not just the instances.
- Cross-references: 801-qasc (the daily-maintenance marker), 737-zcj5 (the MCP
  outage record), 801-m9tk (the surface attestation), 682-m8ek.

## The one-line version

`sed 's/.*\bfield=\(...\).*/\1/p'` matches **nothing** under BSD sed. Every
reader written that way fails closed, and all three of ours were written that
way — so on macOS each gate's `stamp`/`attest` wrote a correct record that its
own `check` could never read back.

## How it surfaced

This cycle's Start-Of-Day gate ran `scripts/check-daily-maintenance.sh check`
and got `due:no-marker`, ran the maintenance body, stamped it, and got:

```
$ scripts/check-daily-maintenance.sh stamp --host macos-tlatoani --steps '...'
ok:daily-maintenance-stamped:2026-08-17
$ scripts/check-daily-maintenance.sh check
due:unreadable-marker
```

The marker on disk was well-formed and dated today. `show` printed it fine. Only
`check` could not read it.

## The mechanism, confirmed

`scripts/check-daily-maintenance.sh:81-87` (before the fix):

```sh
marker_date() {
    [ -f "$MARKER" ] || return 1
    sed -n 's/.*\bdate=\([0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]\).*/\1/p' \
        "$MARKER" 2>/dev/null | grep -m1 . || return 1
}
```

Against the real marker on this host:

```
$ sed -n 's/.*\bdate=\([0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]\).*/\1/p' "$M"
            # (no output)
$ sed -n 's/.*date=\([0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]\).*/\1/p' "$M"
2026-08-17
```

`/usr/bin/sed` on Darwin is BSD sed; `\b` is a GNU BRE extension it does not
implement. It is not an error — the atom simply never matches, `sed` exits 0, and
the caller sees empty output.

## Why this is worse than a normal portability bug

Every one of these readers is *deliberately* fail-closed, because a corrupt
marker read as current is a false green. That is the right design. But it means
the platform failure is **indistinguishable from the state the gate exists to
detect**:

| Gate | Real state on macOS | What it reported |
|---|---|---|
| `check-daily-maintenance.sh` | stamped today | `due:unreadable-marker` — permanently due, marker write-only |
| `check-mcp-surface.sh` | `claim=exposed` stamped | `unattested:no-surface-claim` |
| `cycle-metrics.sh` | claim present | surface silently dropped from the `mcp:` line |

So macOS re-ran the full daily maintenance body every cycle forever, and the one
fact only the agent can report — whether the MCP tools actually reached its
session (801-m9tk) — was discarded on every macOS cycle. The read path most
likely to be degraded is the one whose degradation could not be recorded.

## The self-tests were right; nothing had run them here

Both scripts ship a `fixture` mode, and both are honest. Run on this host
*before* the fix:

```
$ scripts/check-daily-maintenance.sh fixture ; echo $?
FAIL: stamped-today-reads-current expected 'ok:daily-maintenance-current:2026-08-17' rc=0, got 'due:unreadable-marker' rc=1
FAIL: yesterdays-stamp-is-due-not-current expected 'due:stale:2026-08-16' rc=1, got 'due:unreadable-marker' rc=1
1

$ scripts/check-mcp-surface.sh fixture ; echo $?
FAIL: healthy-handshake-plus-unexposed-surface-is-its-own-state ...
FAIL: both-halves-good-is-ok expected 'ok:surface-exposed' rc=0, got 'unattested:no-surface-claim' rc=3
FAIL: a-stale-claim-does-not-vouch-for-this-cycle ...
FAIL: a-fresh-claim-still-counts expected 'ok:surface-exposed' rc=0, got 'unattested:no-surface-claim' rc=3
1
```

Six failures, correct exit codes, no ambiguity. **The gap was never the test — it
was that no BSD-userland host executed it.** These scripts landed on 2026-08-17
and became gates the same day, validated on Linux. `./build.sh --check` is green
on Linux and does not run these fixtures on macOS.

That is the reusable lesson, and it generalises past `\b`: a fixture that only
ever runs on the platform it was authored on validates the author's assumptions,
not the contract. This host is the fleet's declared bash-3.2/BSD floor, so it is
the host that has to run them.

## The fix

Split on spaces and anchor the field name, instead of approximating a field
boundary with `\b`:

```sh
tr ' ' '\n' < "$MARKER" 2>/dev/null \
    | sed -n 's/^date=\([0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]\)$/\1/p' \
    | grep -m1 . || return 1
```

Field values in all three record formats contain no spaces (the original readers
capture `[^ ]*`, which says so), so a space split lands exactly on field
boundaries. This is portable to both seds and is *strictly more precise* than
`\b` was: `^field=` anchored to a real boundary cannot match a suffix the way a
word-boundary approximation invites.

Applied at three sites:

- `scripts/check-daily-maintenance.sh` — `marker_date()`
- `scripts/check-mcp-surface.sh` — `stamp_field()`
- `scripts/cycle-metrics.sh` — the `claim=` / `epoch=` reads that fold the
  surface attestation into the `mcp:` line

Verified on this host after the fix:

```
$ scripts/check-daily-maintenance.sh fixture   # 10 ok, 0 FAIL, exit 0
$ scripts/check-mcp-surface.sh fixture         # 11 ok, 0 FAIL, exit 0
$ scripts/check-daily-maintenance.sh check
ok:daily-maintenance-current:2026-08-17        # first time this has ever passed here
$ scripts/cycle-metrics.sh | grep mcp
mcp: servers=2 per_server=cli=3955;forge-plan=49 legacy_untagged=0 health=down:project-info ...
mcp_outage: records=1 health=down:project-info log=/tmp/forge-expert-health.jsonl ...
```

The `mcp_outage:` line is the payoff: this cycle's genuine `project-info` outage
now reaches the ledger, which is exactly what 737-zcj5 built the mechanism for
and what the broken reader was suppressing.

## Residual — not fixed here

- `scripts/regenerate-readme.sh:64` uses **two** GNU-only constructs in one
  expression: `sed 's/\b\(.\)/\u\1/g'`. `\u` (upcase next char) is a GNU
  replacement extension with no BSD equivalent, so the title-casing silently
  no-ops on macOS. Not fixed this cycle because it is not in `./build.sh --check`
  — it is reachable only through the optional pre-push hook
  (`scripts/install-readme-pre-push-hook.sh:34-43`), so its blast radius is a
  cosmetically wrong README rather than a false gate verdict. Worth a follow-up;
  the `\u` half needs a real rewrite, not a boundary swap.
- `scripts/check-no-base64-script-injection.sh:23` has `\b` inside an ERE passed
  to `grep -E`. Not confirmed broken: this host runs ugrep-as-grep, which does
  support `\b`, so the behaviour depends on which grep is installed. Flagged
  rather than changed, because "works here" is not evidence for the fleet and a
  blind edit to an injection guard is worse than a measured one.

## Proposed constraint (a verifiable one, not prose)

The instances are fixed; the class is not. The smallest guard that would have
caught all three: a check that greps committed shell for GNU-only sed/grep atoms
(`\b`, `\u`, `\U`, `\L`, `\+`, `\?`) and fails loud, plus running the existing
`fixture` modes on the macOS host in its cycle rather than trusting Linux CI.
Filed as the reduction step for 803-bqte rather than implemented here, because
the atom list needs review before it becomes a gate that can block a push.
