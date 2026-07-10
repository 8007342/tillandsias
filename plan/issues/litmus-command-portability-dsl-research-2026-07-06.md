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

## Corpus Analysis (2026-07-10)

Surveyed all 198 `openspec/litmus-tests/*.yaml` files (1044 `command:` fields).
Ranked by frequency:

| Primitive shape | Count | Notes |
|---|---:|---|
| `grep -Fq` / `grep -qF` (quiet literal) | 112 | Existence check, no output |
| `grep -F` (non-quiet literal) | ~430 | Output piped to `awk`, `head`, etc. |
| `grep -cF` + `awk` threshold | 40 | Count + numeric assert |
| `test`/`[` conditionals | 125 | `-e`, `-f`, `-s`, `-z`, `-n`, `-eq`, `-ge` |
| `for` loops (N-of-M files) | 49 | Iterate files, assert each |
| `awk` (threshold/format) | 55 | `if ($1+0 >= N) print ok` |
| `grep -cE` / `grep -Eq` (regex) | 64 | Regex match (count or quiet) |
| `!` negation | ~30 | Assert absence |
| `cat`/`sed`/`find` | 60 | File reading, transformation |
| `echo ok`/`exit 1` | 168+168 | Verdict output |

**Key finding**: 74% of all commands are grep-based. The "dialect-sensitive
escape hell" class (regex metacharacters `|`, `[`, `(`, `)`, `.` in `grep -E`
patterns) affects ~64 commands — small in absolute terms but high in
blast radius (each fix touches 2-3 hosts independently).

## Design Decisions

### D1: Substitution model — **(b) shell functions in a sourced library**

Chosen: `scripts/litmus-stdlib.sh` sourced into the execution context.
Each named token becomes a shell **function** called with arguments.

Rationale:
- Closest to the operator's `${TOKEN}` vision while staying as "a shell line".
- Functions compose naturally: `$(mf_literal "$FILE" "$PATTERN")`.
- Easy to test in isolation (source the lib, call a function).
- No regex preprocessing pass to maintain — the runner stays simple.
- Smallest diff: `run-litmus-test.sh` adds one `source` line; existing
  `command:` strings continue to work as raw shell.

Rejected alternatives:
- (a) Preprocessing pass: string-level substitution is fragile (nested quotes,
  variable interpolation), and hard to debug when it goes wrong.
- (c) Declarative steps: too large a rewrite of both runner and all 198 files.

### D2: Primitives — **8 core functions, mined from the corpus**

| Function | Replaces | Count | Signature |
|---|---|---:|---|
| `mf_literal` | `grep -Fq "$PAT" "$FILE"` | 112 | `mf_literal FILE PATTERN` — exit 0 if found |
| `mf_literal_count` | `grep -cF "$PAT" "$FILE"` | 40 | `mf_literal_count FILE PATTERN` — prints count |
| `mf_regex` | `grep -Eq "$PAT" "$FILE"` | 34 | `mf_regex FILE PATTERN` — portably escapes for the host's `grep -E` |
| `mf_regex_count` | `grep -cE "$PAT" "$FILE"` | 30 | `mf_regex_count FILE PATTERN` — prints count |
| `mf_absent` | `! grep -qF "$PAT" "$FILE"` | 30 | `mf_absent FILE PATTERN` — exit 0 if NOT found |
| `mf_threshold` | `grep -cF ... \| awk '{if ($1>=N)}'` | 40 | `mf_threshold FILE PATTERN MIN_COUNT` — exit 0 if count >= MIN |
| `mf_file_exists` | `test -e "$FILE"` / `test -f "$FILE"` | 14 | `mf_file_exists FILE` — exit 0 if exists |
| `mf_assert_count` | `test "$N" -eq "$M"` | 8 | `mf_assert_count ACTUAL EXPECTED` — exit 0 if equal |

**NOT included** (escape-hatch territory, not worth abstracting):
- `awk` one-liners (55 uses, all bespoke — keep as raw `command:`)
- `sed` transformations (21 uses, each unique)
- `find` operations (14 uses, each unique)
- `for` loops (49 uses — these are structural, not a single primitive; authors
  compose them with `mf_literal`/`mf_regex` inside the loop body)

### D3: Per-OS resolution — **single file with `case` branching**

`scripts/litmus-stdlib.sh` contains all 8 functions. Each function internally
branches on `$(uname -s)` where the dialect differs (currently only `mf_regex`
and `mf_regex_count` — GNU vs BSD `grep -E` regex escaping). Authors never
see the branching; it's invisible.

The file is ~80 lines. Maintained in one place. No per-host override files.

### D4: Migration — **lint + pin + lazy convert**

1. Add a **drift-protection litmus** (`litmus:litmus-stdlib-portability-shape`)
   that greps new/changed `command:` fields for raw `\|`, `\(`, `\[` in
   `grep -E` context and fails if found.
2. New files must use `mf_*` functions for the 8 core patterns.
3. Existing files are converted **lazily** — when touched for any reason.
4. The 4 files from this cycle's fixes (`forge-environment-discoverability`,
   `forge-opencode-onboarding`, `zen-default-with-ollama`, `litmus-versioning-shape`)
   are the first migration batch (they already carry "hand-derived escape"
   comments).

### D5: Escape hatch — **raw `command:` remains valid**

A `command:` that uses no `mf_*` functions is treated as raw shell (today's
behavior). The stdlib is sourced regardless, so `mf_*` functions are available
even in raw commands if authors discover them mid-edit. No syntax change to
the YAML schema — `command:` is still a string.

## Prototype: 5 real command fields rewritten

### P1: Regex with portably-escaped metacharacters

**Before** (from `litmus-runner-command-backslash-escaping-2026-07-06`):
```yaml
command: "grep -cE '^    \\\"(Foo|Bar)\\\\|' target/file.log | awk '{ if ($1+0 >= 2) print \"ok:\", $1; else { print \"FAIL:\"; exit 1 } }'"
```

**After**:
```yaml
command: "count=$(mf_regex_count target/file.log '^    \"(Foo|Bar)\\|'); mf_threshold_std $count 2"
```

The `\|` → `|` inside `mf_regex_count` is handled by the function: it knows
whether to add a GNU-specific `\|` escape or leave it as `|` (BSD) based on
`uname -s`.

### P2: Quiet literal existence check

**Before** (common pattern, ~112 instances):
```yaml
command: "grep -qF 'tillandsias-forge' Containerfile && echo ok || echo FAIL"
```

**After**:
```yaml
command: "mf_literal Containerfile tillandsias-forge && echo ok || echo FAIL"
```

No dialect sensitivity in `grep -F` today, but the function future-proofs
against GNU/BSD flag-ordering differences and gives a uniform review surface.

### P3: Count + threshold

**Before** (from `litmus-runner-command-backslash-escaping`):
```yaml
command: "grep -cF '@trace spec:app-lifecycle' crates/tillandsias-core/src/state.rs | awk '{ if ($1+0 >= 10) print \"ok:\", $1, \"app-lifecycle traces\"; else { print \"FAIL: only\", $1, \"of >=10\"; exit 1 } }'"
```

**After**:
```yaml
command: "count=$(mf_literal_count crates/tillandsias-core/src/state.rs '@trace spec:app-lifecycle'); mf_threshold_std $count 10 && echo \"ok: $count app-lifecycle traces\" || { echo \"FAIL: only $count of >=10\"; exit 1 }"
```

### P4: Assert absence (negated literal)

**Before**:
```yaml
command: "! grep -qF ':latest' run-forge-standalone.sh && echo 'ok: no :latest' || { echo 'FAIL: :latest found'; exit 1 }"
```

**After**:
```yaml
command: "mf_absent run-forge-standalone.sh ':latest' && echo 'ok: no :latest' || { echo 'FAIL: :latest found'; exit 1 }"
```

### P5: N-of-M files loop

**Before** (from `litmus-forge-environment-discoverability`):
```yaml
command: "for s in opencode opencode-web claude codex; do grep -Fq \"entrypoint-forge-$s.sh\" images/default/Containerfile || { echo \"FAIL: entrypoint-forge-$s.sh not COPY'd\"; exit 1; }; done && echo \"ok: 4 forge entrypoints present\""
```

**After**:
```yaml
command: "for s in opencode opencode-web claude codex; do mf_literal images/default/Containerfile \"entrypoint-forge-$s.sh\" || { echo \"FAIL: entrypoint-forge-$s.sh not COPY'd\"; exit 1; }; done && echo \"ok: 4 forge entrypoints present\""
```

Minimal change — the loop structure stays, only the grep call is replaced.

## Acceptance Evidence

- ✅ Written design doc/decision answering questions 1–5 with concrete choices.
- ✅ 5 real existing `command:` fields rewritten in the token form.
- Pending (implementation packet): Working `scripts/litmus-stdlib.sh` with
  all 8 functions; the 5 prototype commands passing identically to their raw
  form; drift-protection litmus registered.
