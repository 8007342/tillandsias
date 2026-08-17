# forge-e2e-rate-limit.sh: a check against an unknown class name always allows

- classification: enhancement
- filed: 2026-08-16 (windows, meta-orchestration cycle 2)
- status: open
- related: litmus:forge-e2e-rate-limit-shape ("fresh class allows" is pinned by design)

## Observation

On 2026-08-16 (cycle 1) this host ran
`scripts/forge-e2e-rate-limit.sh check full-cycle` and got `allow` ~1.5h after
the 06:05Z full curl-install smoke, and read that as a possible rate-limit
accounting bug. Verified this cycle (cycle 2): it is not an accounting bug —
two separate facts compose into the confusion:

1. **There is no class named `full-cycle`.** The canonical class is
   `full-meta` (used by `scripts/litmus-opencode-e2e-launch.sh` for both
   `check` and `record`); `diagnostics` is the only other class ever stamped
   on this host. The limiter's own header prose called it "the full-cycle
   e2e", which is what suggested the wrong slug — fixed in the same commit as
   this filing.
2. **The 06:05Z run recorded nothing, correctly.** It was the curl-install
   smoke re-run of tag v0.4.260815.1 with "Forge --opencode lane N/A on
   Windows" (plan/loop_status.d/20260816t060440z-05108a10-windows.md) — no
   full in-forge meta e2e ran, so no `full-meta` stamp was due. Stamps on this
   host: diagnostics=2026-08-14T19:44:01Z, full-meta=2026-08-14T19:45:09Z.

## The residual footgun

`check <anything>` against a class that has never been recorded prints
`allow:<class>` and exits 0. A typo'd class slug in an automation caller
therefore silently DISABLES the limiter for that caller — the check passes
forever because the stamp it consults can never be written under the name the
recorder uses. "Allow because the window expired" and "allow because no such
class exists" are indistinguishable in both grammar and exit code.

This cannot be fixed by refusing unknown classes outright:
litmus:forge-e2e-rate-limit-shape pins "fresh class allows" (a legitimately
new class's first run must allow — the litmus itself relies on it with its
`litmus-probe` class).

## Smallest next action

Distinguish the two allows without breaking first-run-allows: e.g. extend the
grammar to `allow:<class>:first-run` when no stamp file exists (grammar
change, so update litmus:forge-e2e-rate-limit-shape in the SAME commit), or
have callers pass `--expect-recorded` when they believe the class has run
before. Either way the caller can then notice it is asking about a class the
recorder never writes. Needs a deliberate grammar decision, not a drive-by
edit — the current grammar is pinned and consumed by the launch wrapper.
