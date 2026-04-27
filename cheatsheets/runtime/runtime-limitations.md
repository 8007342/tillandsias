---
tags: [forge, runtime-limitations, feedback-loop, agent-workflow, meta]
languages: []
since: 2026-04-25
last_verified: 2026-04-27
sources:
  - https://github.com/8007342/tillandsias/blob/main/openspec/specs/agent-cheatsheets/spec.md
authority: high
status: current

# v2 — tier classification (cheatsheets-license-tiered)
tier: pull-on-demand
summary_generated_by: hand-curated
bundled_into_image: false
committed_for_project: false
pull_recipe: see-section-pull-on-demand
---

# RUNTIME_LIMITATIONS_NNN.md — feedback loop

@trace spec:agent-cheatsheets

## Provenance

This file documents the Tillandsias-internal feedback format for reporting forge limitations. The authority is the Tillandsias project itself.
- OpenSpec agent-cheatsheets spec (defines the runtime-limitations reporting contract): <https://github.com/8007342/tillandsias/blob/main/openspec/specs/agent-cheatsheets/spec.md>
- **Last updated:** 2026-04-25

**Version baseline**: Tillandsias 0.1.169.x
**Use when**: you (the agent) tried to do something the forge can't, AND working around it would be wrong. Report it. Don't hide it.

## Quick reference

| Field | Required? | Format | Example |
|---|---|---|---|
| `report_id` | yes | 3-digit, zero-padded, sequential | `003` |
| `tool` | yes | the missing tool / capability name | `protoc-gen-go` |
| `attempted` | yes | one line — what you tried to do | `Compile foo.proto with the Go plugin` |
| `suggested_install` | yes | one line — what you'd run on a non-restricted host | `go install google.golang.org/protobuf/cmd/protoc-gen-go@latest` |
| `discovered_at` | yes | ISO 8601 | `2026-04-25T18:30:00Z` |
| body | yes | 3–10 lines | (free-form) |

| Path | Why |
|---|---|
| `<project>/.tillandsias/runtime-limitations/RUNTIME_LIMITATIONS_<NNN>.md` | host's mirror-sync brings the dir back on forge stop |

## Common patterns

### Pattern 1 — write a report

```bash
DIR="$HOME/src/<project>/.tillandsias/runtime-limitations"
mkdir -p "$DIR"
NEXT=$(ls "$DIR" 2>/dev/null | grep -oE '[0-9]{3}' | sort -n | tail -1)
NEXT=$(printf '%03d' $((10#${NEXT:-0} + 1)))
FILE="$DIR/RUNTIME_LIMITATIONS_${NEXT}.md"

cat > "$FILE" <<EOF
---
report_id: ${NEXT}
tool: <name>
attempted: <one line>
suggested_install: <one line>
discovered_at: $(date -u +%Y-%m-%dT%H:%M:%SZ)
---

# Runtime limitation ${NEXT} — <one-line headline>

<3-10 lines>
EOF
```

Commit it. The next mirror-sync brings it back to the host.

### Pattern 2 — front-matter + body example

```markdown
---
report_id: 007
tool: protoc-gen-go
attempted: Compile foo.proto with the Go plugin
suggested_install: go install google.golang.org/protobuf/cmd/protoc-gen-go@latest
discovered_at: 2026-04-25T18:30:00Z
---

# Runtime limitation 007 — protoc-gen-go missing

`protoc` is in the forge but the Go plugin (`protoc-gen-go`) isn't. Without
it, `protoc --go_out=.` fails with `protoc-gen-go: program not found`.

Worked around by skipping codegen for this iteration; the human will need
to either add `protoc-gen-go` to the forge image, or accept that codegen
happens on the host before forge attach.
```

### Pattern 3 — when NOT to report

- The tool exists but you didn't read the cheatsheet first. Always check `$TILLANDSIAS_CHEATSHEETS/INDEX.md` before reporting "tool X is missing".
- The behavior you want is project-specific (e.g., a missing dep in `package.json`). Run `npm install` in the project — that's a normal install, not a forge limitation.
- You can solve it with a per-project virtualenv, `cargo install --root <project>/...`, or similar project-scoped install.

### Pattern 4 — when DEFINITELY to report

- A binary you'd expect on a normal dev machine isn't here.
- A library can't be installed because pip/npm-global try to write to `/usr` (read-only).
- A capability is missing (e.g., GPU passthrough into the forge for ML).
- The cheatsheet for tool X says it should exist but `which X` returns nothing.

## Common pitfalls

- **Editing the cheatsheet directly inside the forge** — `/opt/cheatsheets/` is read-only image-state. Even if you're sure the cheatsheet is wrong, the right action is a RUNTIME_LIMITATIONS report (or a host-side spec change), NOT an in-place edit.
- **Skipping `discovered_at`** — without a timestamp the host can't tell if the report is fresh or stale.
- **Vague `attempted` / `suggested_install`** — a report of "tool X is missing" is useless. The host needs to know exactly what you tried so they can reproduce, and exactly what install command would have worked elsewhere.
- **NNN collisions** — two parallel agents in the same project might both write `008`. The mirror-sync de-conflicts by file content; agents SHOULD `ls` immediately before writing to minimise the window. If a collision happens, the host can rename one report manually — minor pain, not a data loss.
- **Reporting the same gap twice** — `rg <tool>` against existing reports before writing a new one. If a report already exists, augment its body with a new `## Encountered again on <date>` section instead of creating a duplicate.

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
  - `https://github.com/8007342/tillandsias/blob/main/openspec/specs/agent-cheatsheets/spec.md`
- **Archive type:** `single-html`
- **Expected size:** `~1 MB extracted`
- **Cache target:** `~/.cache/tillandsias/cheatsheets-pulled/$PROJECT/github.com/8007342/tillandsias/blob/main/openspec/specs/agent-cheatsheets/spec.md`
- **License:** see-license-allowlist
- **License URL:** https://github.com/8007342/tillandsias/blob/main/openspec/specs/agent-cheatsheets/spec.md

### Materialize recipe (agent runs this)

```bash
set -euo pipefail
TARGET="$HOME/.cache/tillandsias/cheatsheets-pulled/$PROJECT/github.com/8007342/tillandsias/blob/main/openspec/specs/agent-cheatsheets/spec.md"
mkdir -p "$(dirname "$TARGET")"
curl --fail --silent --show-error \
  "https://github.com/8007342/tillandsias/blob/main/openspec/specs/agent-cheatsheets/spec.md" \
  -o "$TARGET"
```

### Generation guidelines (after pull)

1. Read the pulled file for the structure relevant to your project.
2. If the project leans on this tool/topic heavily, generate a project-contextual
   cheatsheet at `<project>/.tillandsias/cheatsheets/runtime/runtime-limitations.md` using
   `cheatsheets/TEMPLATE.md` as the skeleton.
3. The generated cheatsheet MUST set frontmatter:
   `tier: pull-on-demand`, `summary_generated_by: agent-generated-at-runtime`,
   `committed_for_project: true`.
4. Cite the pulled source under `## Provenance` with `local: <cache target above>`.

## See also

- `runtime/forge-container.md` — the runtime contract that creates these limitations
- `agents/openspec.md` — the host workflow for promoting a RUNTIME_LIMITATIONS report into a forge image change
