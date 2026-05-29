---
tags: []  # TODO: add 3-8 kebab-case tags on next refresh
languages: []
since: 2026-04-25
last_verified: 2026-04-27
sources:
  - https://mikefarah.gitbook.io/yq/
  - https://github.com/mikefarah/yq
authority: high
status: current

# v2 — tier classification (cheatsheets-license-tiered)
tier: pull-on-demand
summary_generated_by: hand-curated
bundled_into_image: false
committed_for_project: false
pull_recipe: see-section-pull-on-demand
---
# yq — mikefarah/yq

@trace spec:agent-cheatsheets

**Version baseline**: mikefarah/yq 4.x (added to forge by `agent-source-of-truth` change).
**Use when**: querying or updating YAML files in the forge — Kubernetes manifests, GitHub Actions workflows, Compose files, Helm values. (NOT the kislyuk Python `yq` wrapper around jq — that is a different binary with different syntax.)

## Provenance

- mikefarah/yq documentation (official GitBook): <https://mikefarah.gitbook.io/yq/> — complete operator and flag reference
- mikefarah/yq GitHub repository: <https://github.com/mikefarah/yq> — release notes, README, version history
- **Last updated:** 2026-04-25

Verified: `-i` in-place edit confirmed in documentation with example `yq -i '.a.b[0].c = "cool"' file.yaml`; `ea` (eval-all) processes all files together (confirmed); `strenv(VAR)` reads as string while `env(VAR)` parses as YAML (Norway problem — confirmed in yq docs). `-o json` output format, `-P` pretty-print, and `select()` pipe syntax confirmed.

## Quick reference

| Command / Flag | Effect |
|---|---|
| `yq '.a.b' f.yaml` | Evaluate expression on each document (default `eval` / `e`). |
| `yq ea '...' f.yaml` | `eval-all`: load **all** docs into one stream as `..` indexable. |
| `yq -i '...' f.yaml` | In-place edit (rewrites file; preserves comments best-effort). |
| `yq -o json f.yaml` | Output as JSON (also `-o yaml` default, `-o tsv`, `-o csv`, `-o xml`, `-o props`). |
| `yq -P f.yaml` | Pretty-print / canonicalize YAML (re-emits with consistent style). |
| `yq -r '.x' f.yaml` | Raw string output (strip surrounding quotes — like jq `-r`). |
| `yq --from-file expr.yq f` | Read expression from a file (multi-line scripts). |
| `yq -n '...'` | Null input — construct YAML from scratch. |
| `yq '.[] \| select(.k == "v")' f` | Pipes and `select` work like jq. |
| `yq 'documentIndex'` | Per-doc index in `eval` mode. |

## Common patterns

### Read a key

```bash
yq '.metadata.name' deployment.yaml
yq '.spec.template.spec.containers[0].image' deployment.yaml
yq '.services.web.ports[]' compose.yaml          # iterate sequence
```

Plain `eval` runs the expression once per document; for single-doc files this is what you want.

### Update in-place

```bash
yq -i '.spec.replicas = 3' deployment.yaml
yq -i '.image = "ghcr.io/org/app:v1.2.3"' values.yaml
yq -i '.env += [{"name":"LOG_LEVEL","value":"debug"}]' deployment.yaml
```

`-i` rewrites the file. Comments survive in most cases but exact whitespace and key order may change — review the diff before committing.

### Multi-document files (eval-all)

```bash
yq ea '. as $item ireduce ({}; . * $item)' kustomize-bundle.yaml   # merge all docs
yq ea 'select(.kind == "Deployment")' bundle.yaml                  # pick docs by field
yq ea '[.]' bundle.yaml                                            # collect docs into a sequence
```

`ea` (`eval-all`) is the right mode whenever you need to see across `---` boundaries. Plain `eval` only sees one doc at a time.

### Script from file

```bash
# patch.yq
.metadata.labels.env = strenv(ENV)
| .spec.replicas = (strenv(REPLICAS) | tonumber)

ENV=prod REPLICAS=5 yq -i --from-file patch.yq deployment.yaml
```

`strenv(VAR)` reads as string; use `env(VAR)` to parse the value as YAML (boolean/number coercion). Pair with `--from-file` for anything beyond a one-liner.

### Convert YAML to JSON (and back)

```bash
yq -o json '.' values.yaml > values.json
yq -p json -o yaml '.' values.json > values.yaml      # JSON in, YAML out
yq -o json -I 0 '.' values.yaml | jq '.image'         # pipe to jq compact
```

`-p` sets the **input** parser; `-o` sets the output. `-I 0` disables indentation (compact JSON).

## Common pitfalls

- **Wrong yq** — mikefarah/yq (Go, jq-like DSL) and kislyuk/yq (Python wrapper that pipes through jq) share a name and conflict on `$PATH`. Forge ships **mikefarah**. Check with `yq --version`; kislyuk prints `yq <ver>` and a Python path, mikefarah prints `yq (https://github.com/mikefarah/yq/) version 4.x`.
- **`eval` vs `eval-all` on multi-doc files** — `yq '.kind' bundle.yaml` prints `kind` for each doc separately; `yq ea '[.kind]' bundle.yaml` collects them into one sequence. Reaching across docs (merge, dedupe, count) requires `ea`.
- **In-place rewrites reformat** — `-i` round-trips through the AST. Long-line wrapping, anchor expansion (`<<: *defaults` may be inlined), and key ordering can shift. Diff before committing; for cosmetically-sensitive files (Helm charts under review), prefer a targeted `sed`.
- **Comment loss on structural edits** — comments attached to a removed/replaced node disappear. Adding keys preserves siblings' comments; deleting a parent drops everything under it.
- **Dotted keys need quoting** — `.foo.bar` walks two levels; a literal key named `foo.bar` must be `."foo.bar"`. Same trap as jq: `."kubernetes.io/role"`.
- **Boolean/number coercion via `env()`** — `env(X)` parses the value as YAML, so `X=NO` becomes `false` (the Norway problem — see `languages/yaml.md`). Use `strenv(X)` whenever the value is meant to stay a string.
- **`-r` is not the default** — string scalars print with no surrounding quotes by default (unlike jq), but complex output may still include YAML quoting. Use `-r` (or output as JSON and pipe to `jq -r`) when feeding shells.
- **Update vs assign** — `.x = 1` always sets; `.x |= . + 1` updates in place using the current value. Forgetting `|=` and writing `.x = .x + 1` fails when `.x` is null on first run.
- **Style flags affect diffs, not semantics** — `-P` (pretty), `-I N` (indent), `--no-colors` change output formatting only. Pin them in scripts that produce committed files so reviewers see semantic diffs only.

## Pull on Demand

> This cheatsheet's underlying source is NOT bundled into the forge image.
> Reason: upstream license redistribution status not granted (or off-allowlist).
> See `cheatsheets/license-allowlist.toml` for the per-domain authority.
>
> When you need depth beyond the summary above, materialize the source into
> the per-project pull cache by following the recipe below. The proxy
> (HTTP_PROXY=http://proxy:3128) handles fetch transparently — no credentials
> required.

<!-- TODO: hand-curate the recipe before next forge build -->

### Source

- **Upstream URL(s):**
  - `https://mikefarah.gitbook.io/yq/`
- **Archive type:** `single-html`
- **Expected size:** `~1 MB extracted`
- **Cache target:** `~/.cache/tillandsias/cheatsheets-pulled/$PROJECT/mikefarah.gitbook.io/yq/`
- **License:** see-license-allowlist
- **License URL:** https://mikefarah.gitbook.io/yq/

### Materialize recipe (agent runs this)

```bash
set -euo pipefail
TARGET="$HOME/.cache/tillandsias/cheatsheets-pulled/$PROJECT/mikefarah.gitbook.io/yq/"
mkdir -p "$(dirname "$TARGET")"
curl --fail --silent --show-error \
  "https://mikefarah.gitbook.io/yq/" \
  -o "$TARGET"
```

### Generation guidelines (after pull)

1. Read the pulled file for the structure relevant to your project.
2. If the project leans on this tool/topic heavily, generate a project-contextual
   cheatsheet at `<project>/.tillandsias/cheatsheets/utils/yq.md` using
   `cheatsheets/TEMPLATE.md` as the skeleton.
3. The generated cheatsheet MUST set frontmatter:
   `tier: pull-on-demand`, `summary_generated_by: agent-generated-at-runtime`,
   `committed_for_project: true`.
4. Cite the pulled source under `## Provenance` with `local: <cache target above>`.

## See also

- `utils/jq.md` — sister CLI for JSON; mikefarah yq deliberately mirrors jq's expression language
- `languages/yaml.md` — YAML semantics, quoting rules, and the Norway problem in detail
- `languages/json.md` — output target when piping yq into JSON-only tools
