# Runtime Limitations Reporting

@trace spec:agent-source-of-truth

**Version baseline**: Tillandsias forge image (v0.1.170+)  
**Use when**: The forge lacks a tool you need, or a baked tool behaves unexpectedly due to the offline/isolated runtime

## Provenance

- https://github.com/8007342/tillandsias/blob/main/openspec/changes/agent-source-of-truth/design.md — Decision 6: RUNTIME_LIMITATIONS format
- https://github.com/containers/podman/docs — Container isolation semantics
- **Last updated:** 2026-04-27

## Quick reference

**Report format**: YAML front-matter + markdown body

```markdown
---
report_id: NNN
tool: <missing-tool-name>
attempted: <what you tried to do>
suggested_install: <how you would install it on a normal Linux box>
discovered_at: <ISO 8601 timestamp>
---

# Runtime Limitation NNN — <one-line headline>

<3–10 lines of explanation>
```

**Report location**: `<project>/.tillandsias/runtime-limitations/RUNTIME_LIMITATIONS_NNN.md`  
**NNN assignment**: Glob `.tillandsias/runtime-limitations/`, find max NNN, increment by 1.

## Common patterns

**Reporting a missing tool:**

```bash
# Inside the forge, when you discover a missing tool
mkdir -p .tillandsias/runtime-limitations
ls .tillandsias/runtime-limitations/RUNTIME_LIMITATIONS_*.md 2>/dev/null | wc -l  # Find next number

cat > .tillandsias/runtime-limitations/RUNTIME_LIMITATIONS_001.md << EOF
---
report_id: 001
tool: protoc
attempted: "protobuf code generation for gRPC service"
suggested_install: "apt-get install protobuf-compiler"
discovered_at: 2026-04-27T14:33:00Z
---

# Runtime Limitation 001 — Missing protoc for gRPC codegen

The forge lacks protobuf-compiler. gRPC service definition (*.proto) compiles on the host
but code generation must happen there too, or we accept manual *.pb.* files in the repo.

**Workaround**: Commit *.pb.go files to git; the forge agents can use them as-is.
