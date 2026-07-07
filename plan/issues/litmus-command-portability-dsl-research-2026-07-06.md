# Research: a readable, portable building-block DSL for litmus `command:` fields — 2026-07-06

- class: research
- filed: 2026-07-06
- owner: any (design decision affects every host that writes litmus files)
- status: ready
- trace: plan/issues/litmus-runner-command-backslash-escaping-2026-07-06.md,
  plan/issues/litmus-full-suite-macos-first-run-findings-2026-07-06.md

## Problem

`openspec/litmus-tests/*.yaml` `command:` fields are raw shell one-liners,
hand-escaped for a custom, non-YAML-aware extractor
(`scripts/run-litmus-test.sh`'s `command:\ \"(.+)\"` regex + a manual
`\"`/`\\` unescape pass). This has produced a recurring, expensive class of
cross-host breakage this cycle alone:

- `\\|` (meant as a literal-pipe escape) parses as escaped-backslash +
  dangling alternation on BSD/macOS `grep`, but GNU `grep` on Linux silently
  tolerates it and over-matches — so it looked fine on Linux and broke on
  macOS with no signal until someone actually ran it there.
- Same shape for `\\[` in an awk regex, and `\${VAR}` in a `grep -E` pattern.
- `mapfile -d ''` and `"${ARR[@]}"` on a possibly-empty array are bash-4+-only
  constructs that silently work on Linux/CI (modern bash) and fail outright
  on stock macOS (`bash` 3.2, frozen pre-GPLv3).
- The extractor itself only unescaped `\"`, never `\\` — so a `command:`
  string that is **valid YAML** and reads correctly under `ruby -ryaml`/`yq`
  could still execute with an *extra* literal backslash at runtime, with **no
  parse error anywhere** to point at the cause. (Fixed in order 201, but the
  underlying authoring experience — hand-computing multi-layer backslash
  arithmetic across YAML-escaping + a partial-unescape shell parser + the
  target tool's own regex dialect — is still what every `command:` author has
  to do by hand today.)
- Two different hosts (macOS this cycle, Linux in an earlier cycle) each
  independently discovered pieces of this same root cause and worked around
  it differently before either landed the real fix — a sign the current
  authoring model doesn't scale across concurrent multi-host contributors.

Windows is not exempt even though its trays are PowerShell/Rust: the
Windows-owned litmus files (e.g. `litmus-windows-tray-diagnose-cli-surface.yaml`)
still run POSIX `grep -F`/`bash -c` checks (via WSL2/Git-Bash), so the actual
fault line isn't "bash vs PowerShell," it's **POSIX tool-dialect divergence**
(GNU vs BSD `grep`/`awk`/`sed`, bash 3.2 vs 4+ builtins) plus a parser that
doesn't fully implement YAML string semantics. Any redesign should account
for this: it is not (today) a 3-way shell-language split, it's an N-way
coreutils/bash-version split that happens to correlate with host OS.

## Operator's proposed direction

Stop authoring `command:` as opaque escaped shell text
(`"grep -cE '^    \\\"(Foo|Bar)\\\\|'..."`) and instead compose it from named,
meaningful building blocks that read like what they do, e.g.:

```yaml
command: "${MATCH_LITERAL_LINE_PREFIX category_regex} ${PIPE} ${COUNT_LINES} ${REDIRECT_TO} ${CATS_VAR}"
```

...where each `${TOKEN}` is a stable, documented primitive (not raw
punctuation soup) that:

1. Is easy to read and review without executing it in your head.
2. Is stable across edits — renaming/reordering a pattern shouldn't require
   re-deriving escape depth.
3. Resolves to the *correct* per-host shell/tool incantation automatically
   (GNU vs BSD `grep`, bash 3.2 vs 4+, and — if ever needed — POSIX shell vs
   PowerShell), so authors don't have to know or care which host will run it.
4. Is easier to `grep`/review/maintain across the ~90 litmus files than
   hand-rolled escape sequences.

## Design questions to resolve (this packet's actual deliverable)

1. **Substitution model.** Is `${TOKEN}` resolved by:
   - (a) a preprocessing pass in `scripts/run-litmus-test.sh` before
     `bash -c`, substituting tokens for host-appropriate shell fragments
     (string-level, keeps `command:` as one shell line); or
   - (b) a small `litmus-stdlib.sh` sourced into the execution context, where
     tokens are actual shell **functions** (`match_literal_line_prefix`,
     `count_lines`, ...) called with arguments, so `command:` becomes a
     sequence of function calls rather than string substitution; or
   - (c) something structured (a list of `steps:` sub-fields instead of one
     opaque string — `op: match_literal`, `args: [...]`), moving further from
     "one command:" toward a tiny declarative pipeline?

   (b) most directly matches the operator's example (`${...}` tokens reading
   as meaningful names) while staying close to today's "it's a shell line"
   model; (c) is the most robust against dialect drift but is the biggest
   rewrite of both the runner and every existing file. Recommend evaluating
   (b) first — smallest diff, biggest fix to the actual pain (backslash/regex
   dialect hell), most reviewable in a single PR.

2. **Which primitives are actually needed?** Survey the ~90 existing
   `openspec/litmus-tests/*.yaml` `command:` fields (this is real, available
   data, not guesswork) and bucket their shapes. From this cycle's fixes
   alone, at minimum:
   - literal-substring match (`grep -F`)
   - regex match with a portably-escaped literal metachar (`.`, `(`, `)`,
     `|`, `[`) — this is THE recurring pain point
   - count-of-matches with a numeric threshold check
   - "N of M files each contain X" loops (`for f in ...; do grep ... || fail;
     done`)
   - pipe chains ending in a fixed success token
   - array collection (NUL-delimited `mapfile`/`readarray` vs bash-3.2
     `while read -d ''`)
   - "assert absence" (`! grep -q ... && echo ok`)
   Do NOT invent primitives speculatively — mine the actual corpus so the
   first cut covers real usage, not imagined usage.

3. **Per-OS resolution mechanism** ("a per-os include line" per the operator's
   ask). Options:
   - A single token library with internal `case "$(uname -s)"` branching per
     primitive (centralizes the dialect knowledge in one file, authors never
     see it).
   - Per-host override files (`litmus-stdlib.linux.sh` /
     `litmus-stdlib.darwin.sh`) sourced conditionally — clearer separation,
     more files to keep in sync.
   - An explicit per-step `os:` field for the rare case a check is
     genuinely OS-specific behavior (not just dialect) rather than a portable
     primitive misapplied.
   Recommend defaulting to the first (dialect knowledge centralized, invisible
   to authors) and reserving an explicit `os:` field only for genuinely
   OS-specific *behavioral* assertions (there are some — e.g. macOS-only
   Info.plist checks), which already exist today as ordinary `command:`
   strings scoped by which spec/host owns the file.

4. **Migration strategy.** ~90 files today. Options: (a) big-bang rewrite
   (risky, large diff, but no dual-format period); (b) new files only, plus
   opportunistic conversion when a file is touched for another reason (slow,
   permanent split between old/new style); (c) a lint/litmus-of-litmus check
   that flags new raw-backslash-regex `command:` strings and requires the
   token form going forward, converting existing files lazily. Recommend (c)
   — matches how order 199-201's fixes already landed (touch-when-broken),
   avoids a risky flag day, and the "regression test protects the fix" pattern
   from order 201 (`litmus:litmus-runner-backslash-escaping-shape`) is a
   template for a "no more raw dialect-sensitive escapes" pin test.

5. **Escape hatch.** Some checks are genuinely bespoke one-offs (a single
   `awk` one-liner used nowhere else) where inventing a named primitive is
   overkill. The design should allow a raw `command:` to coexist
   indefinitely for these — the goal is eliminating the *dialect-sensitive
   escape hell* class of bug, not banning shell entirely.

## Non-goals

- This is not a proposal to replace `bash -c` execution with a different
  runtime (no Python, per `methodology.yaml`'s "Python is not permitted for
  committed automation").
- Not proposing PowerShell-native litmus commands on Windows — current
  evidence (see above) is that WSL2/Git-Bash POSIX checks are already the
  working, load-bearing convention there; don't introduce a second dialect
  split to solve the first one.

## Acceptance Evidence

- A written design doc/decision (can live as an update to this file) that
  answers questions 1–5 above with a concrete choice, not just options.
- A tiny working prototype: 3–5 real existing `command:` fields (drawn from
  this cycle's actual fixes — the `\|`/`\[`/`\\` ones are ideal candidates)
  rewritten in the chosen token form and passing identically to their raw
  form, proving the mechanism before the full implementation packet commits
  to migrating anything at scale.
