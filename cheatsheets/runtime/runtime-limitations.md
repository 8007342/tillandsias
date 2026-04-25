# RUNTIME_LIMITATIONS_NNN.md — feedback loop

@trace spec:agent-cheatsheets

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

## See also

- `runtime/forge-container.md` — the runtime contract that creates these limitations
- `agents/openspec.md` — the host workflow for promoting a RUNTIME_LIMITATIONS report into a forge image change
