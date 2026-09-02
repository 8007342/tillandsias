#!/usr/bin/env bash
# ORDER 956-llei. Run ONE litmus file through the real runner, by path.
#
# The runner selects by SPEC (the positional filter resolves through
# openspec/litmus-bindings.yaml), so a single test cannot be asked for by
# name, an unbound test cannot be run at all, and a test bound under an
# obsolete spec is unreachable — which is how "born red" fixtures stay
# unobserved for weeks. This wrapper builds a temp project root (symlinked
# scripts/ and methodology/, a one-entry bindings file, the one test) and
# runs the real runner there, so the verdict is the runner's verdict, not a
# hand re-execution of the step commands.
#
# Usage: scripts/litmus-run-one.sh <path/to/litmus-*.yaml> [runner args...]
#   e.g. scripts/litmus-run-one.sh openspec/litmus-tests/litmus-foo.yaml --phase pre-build
# Exit code is the runner's. Phase defaults to the file's own phase so a
# retired test asked for by path still runs (that is the explicit ask).
set -uo pipefail

[ $# -ge 1 ] && [ -f "$1" ] || { echo "usage: $0 <litmus-file.yaml> [runner args...]" >&2; exit 2; }
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
file="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"; shift

name="$(sed -n 's/^name: *//p' "$file" | head -1)"
spec="$(sed -n 's/^spec: *//p' "$file" | head -1)"
phase="$(sed -n 's/^phase: *//p' "$file" | head -1)"
[ -n "$name" ] && [ -n "$spec" ] || { echo "refused: $file declares no name:/spec:" >&2; exit 2; }

tmp="$(mktemp -d "${TMPDIR:-/tmp}/litmus-run-one.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/openspec/litmus-tests" "$tmp/methodology" "$tmp/target"
ln -s "$ROOT/scripts" "$tmp/scripts"
ln -s "$ROOT/methodology/litmus.yaml" "$tmp/methodology/litmus.yaml"
# Steps run with the temp root as cwd; relative paths in step commands must
# still reach the real tree, so mirror the tree's top level as symlinks.
for d in "$ROOT"/* "$ROOT"/.[!.]*; do
    b="$(basename "$d")"
    case "$b" in scripts|methodology|openspec|target|.git) continue ;; esac
    ln -s "$d" "$tmp/$b" 2>/dev/null || true
done
ln -s "$ROOT/.git" "$tmp/.git" 2>/dev/null || true
mkdir -p "$tmp/openspec"; for d in "$ROOT"/openspec/*; do
    b="$(basename "$d")"; [ "$b" = litmus-tests ] || [ "$b" = litmus-bindings.yaml ] || ln -s "$d" "$tmp/openspec/$b" 2>/dev/null || true
done
ln -s "$ROOT/methodology"/* "$tmp/methodology/" 2>/dev/null || true
cp "$file" "$tmp/openspec/litmus-tests/$(basename "$file")"
cat > "$tmp/openspec/litmus-bindings.yaml" <<EOF
specs:
  - spec_id: ${spec}
    status: active
    litmus_tests:
      - ${name}
EOF

args=("$@")
case " ${args[*]} " in *" --phase "*) ;; *) [ -n "$phase" ] && args+=(--phase "$phase") ;; esac
echo "litmus-run-one: $name (spec $spec, phase ${phase:-unset}) via $tmp" >&2
(cd "$tmp" && bash "$tmp/scripts/run-litmus-test.sh" "$spec" "${args[@]}")
