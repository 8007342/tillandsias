# litmus runner's `command:` extraction only unescapes `\"`, not `\\` — 2026-07-06

- class: optimization (litmus-runner papercut)
- filed: 2026-07-06
- owner: linux (or whoever next edits `scripts/run-litmus-test.sh` parsing)
- trace: scripts/run-litmus-test.sh (`command:\ \"(.+)\"` extraction, line ~685)

## Finding

While triaging the 14 untriaged litmus failures from
`plan/issues/litmus-full-suite-macos-first-run-findings-2026-07-06.md`, writing
a `command:` string that needed a literal backslash (to escape `.`/`(`/`)` for
`grep -E`) silently misbehaved:

- `scripts/run-litmus-test.sh` extracts each step's `command:` value with a
  bash regex over the raw file bytes (`command:\ \"(.+)\"`), then only
  substitutes `\"` → `"` (see the comment at that line). It does **not**
  collapse `\\` → `\`.
- A real YAML parser (`ruby -ryaml`, `yq`) DOES collapse `\\` → `\` inside a
  double-quoted scalar (that's the only valid YAML escape for a literal
  backslash).
- Net effect: a `command:` string that is valid YAML and reads correctly under
  `ruby -ryaml -e 'YAML.load_file(...)'` can still execute with an *extra*
  literal backslash at runtime, silently breaking any `grep -E` pattern that
  needed `\.`/`\(`/`\)` escaping — the check just always returns "not found"
  with no parse error anywhere.

Concretely: `command: "grep -cE 'config\\.provider\\.vault_secret_name\\(\\)' file"`
is valid YAML (unescapes to `config\.provider\.vault_secret_name\(\)`) but the
runner hands bash the raw `config\\.provider\\.vault_secret_name\\(\\)` text,
which `grep -E` reads as "literal backslash, then any char" — never matching
plain source text. The workaround used this cycle: avoid backslash escapes
entirely (drop parens/dots that need escaping, or accept the slightly looser
match from an unescaped `.`), which works but means `command:` authors can't
rely on normal YAML-string reasoning.

## Why this matters

This is exactly the "the check's own tooling gives no signal" class flagged in
`plan/issues/litmus-full-suite-macos-first-run-findings-2026-07-06.md` (the
cargo/flock-missing finding) — a `[FAIL]` from this bug is indistinguishable
from a real regression, and the only way to notice is manually running the
extracted command by hand, which is what happened here.

## Candidate reduction (not done this cycle — filing per capture discipline)

Either:
(a) teach `get_test_phase`/command-extraction to also collapse `\\` → `\` after
    the `\"` → `"` substitution (matches real YAML semantics), or
(b) document in the litmus-authoring guidance that `command:` strings are
    extracted via a non-YAML-aware regex and backslash escapes should be
    avoided/written single (not YAML-correct) to work at runtime, or
(c) switch `run-litmus-test.sh`'s YAML step-parsing to use `yq`/`ruby -ryaml`
    when available instead of the bash-regex fallback (the script already has
    a `yq`-aware `yaml_get` path for other fields — extend the same treatment
    to `command:`/step parsing).

Not fixed this cycle (scope: the running loop was triaging litmus *content*
drift, not the runner's own parser); filed here for whoever next touches
`scripts/run-litmus-test.sh`'s step-parsing loop.
