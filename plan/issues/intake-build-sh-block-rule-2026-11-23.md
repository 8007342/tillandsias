# Intake: a block-only build.sh edit is not HEAVY — 2026-11-23

@trace order:2250-gwfy, order:2249-tif9, order:2248-zcqh

Follow-up to the intake replay (`plan/issues/intake-replay-on-evictions-2026-11-23.md`,
2249-tif9). That replay found 26 of 57 evicted heads HEAVY under
`./build.sh --changed <base> --intake`, with build.sh named as the guard for
11 of the 22 distinct heads. This row narrows that guard as far as it can go
safely, and records why the rest of HEAVY stays.

## The rule (scripts/gate-changed.sh, intake only)

A build.sh diff is **block-only** when every added or removed line meets two
conditions:
- it is one of these block lines: a comment or blank line, `_step "…"`,
  `if ! _run_lua_decider "scripts/lua/…" 2>&1; then`,
  `if ! _run bash "$SCRIPT_DIR/scripts/…" 2>&1; then`, `_error "…"`,
  `_warn "…"`, `_info "…"`, `exit 1` or `fi`;
- it lies inside the `--check` section.

A block-only diff is not a guard hit. The fixtures on the changed `_run` lines
are selected (`because=build.sh-block`), alongside every fixture whose declared
inputs name build.sh.

Anything else stays `heavy:guard:build.sh`, by the coordinator's ruling:
- a variable, a trap, or any edit to the step loop or the preamble;
- a multi-line block that carries its own state (the #1301 shape).

Without `--intake`, nothing changes. Pinned by
`scripts/lua/test-gate-changed-intake.lua` arms 10-12, and each of three mutants
fails exactly its arm.

## Sizing: the 11 build.sh HEAVY heads

| class | heads | outcome |
|---|---|---|
| block-only, no other guard | 3 (#1108 e8213a968, #1150 eaa986f8f, #1291 a8e1bdbce) | **scoped** |
| block-only, but another guard also changed | 4 | HEAVY (the other guard) |
| machinery (trap, step loop, multi-line stateful blocks) | 4 (incl. #1301 x2, #1295) | HEAVY |

Replay re-run on those heads, at each head's own tree:
- **#1291** is a scored code red that was caught only because it went HEAVY.
  It is now scoped, and intake selects `scripts/test-preflight-fixtures-default-target.sh`,
  its evicting step. **Recall stays 13/13.**
- **#1108** and **#1150** are now scoped too (185 and 224 fixtures).
- **#1301 x2** are real code reds and stay HEAVY, as ruled.

**HEAVY: 26/57 → 23/57 (46% → 40%).**

## Why the rest of HEAVY stays

- **tillandsias-plan sources (5 heads):** kept wide, by ruling. The plan
  binary runs every Lua fixture and most shell guards, so a change there
  really can change them all.
- **with-tillandsias-builder.sh (3) and the shared libs (3):** every fixture
  that runs a build or sources the lib reads them; that coupling is real.
- **build.sh machinery (4):** see above.

About 40% HEAVY is therefore mostly structural, not a selector defect. The
bundle design's HEAVY_MAX=2 would make heavy work queue at this rate, which
phase 2 has to handle (the coordinator has raised this with yoga).

## The structural lever

Every inline build.sh `--check` block that moves into a
`scripts/gate-steps.d/*.step` file stops being a build.sh edit at all. Its next
change touches a `.step` file and its fixture, which intake already scopes
precisely. So the ongoing ports and step migrations shrink HEAVY over time
without any further selector work. Today every block-only build.sh edit is one
that a `.step` file would have made unremarkable.
