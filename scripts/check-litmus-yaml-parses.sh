#!/usr/bin/env bash
# ORDER 933-4gm8. Every litmus definition must load under the sanctioned
# YAML reader, or the runner's metadata fallbacks silently RE-BUCKET it.
#
# THE INSTANCE THAT PROVED IT (2026-08-29, found by lenovinha validating a
# conversion batch): litmus-expert-groundtruth-harness.yaml stopped parsing
# when 888-miiy added a plain-scalar list item containing `: ` — the
# continuation lines scan as keyless mapping keys. Nothing said so. The file
# declares `phase: pre-build` and `severity: critical`; with the parse
# failing, every metadata read fell back to its default and the test sat in
# the RUNTIME bucket — absent from the pre-build suite the whole time, while
# 249/249 printed green. A parse failure did not fail anything; it changed
# which tests run.
#
# So this is a GATE, not a lint: one unparseable file is a red build. The
# sweep costs ~1s for 400+ files because the reader dispatches ledger-free
# (746-htj9). Runs from the checkout root; forge-safe (no podman, no vault).
#
# Verdict grammar (stdout, last line):
#   ok:litmus-yaml-parses:<n>
#   blocked:litmus-yaml-unparseable:<n-broken> (each file's verdict above it)
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

. "$ROOT/scripts/plan-binary-probe.sh"
READER="$(resolve_plan_binary 2>/dev/null || true)"
if [ -z "$READER" ] || [ ! -x "$READER" ]; then
    # No reader is its own named state, not a pass and not this gate's red:
    # cycle-preflight owns building the binary, and a fresh clone must still
    # be able to run unrelated checks. Say so and stand aside.
    echo "skip:litmus-yaml-parses:no-runnable-reader (run scripts/cycle-preflight.sh)"
    exit 0
fi

total=0
broken=0
while IFS= read -r f; do
    total=$((total + 1))
    if ! out="$("$READER" validate-yaml "$f" 2>&1)"; then
        printf '%s\n' "$out"
        broken=$((broken + 1))
    fi
done < <(find "$ROOT/openspec/litmus-tests" -name '*.yaml' | sort)

if [ "$broken" -ne 0 ]; then
    echo "blocked:litmus-yaml-unparseable:$broken"
    exit 1
fi
echo "ok:litmus-yaml-parses:$total"
