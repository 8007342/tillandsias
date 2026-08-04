#!/bin/sh
# Plan/schema status vocabulary divergence check (order 440).
# Exits 0 if plan/index.yaml default_status_values and plan/schema.yaml statuses
# are identical. Emits a one-line verdict:
#   ok:status-vocab-in-sync
#   blocked:status-vocab-diverges: <details>
# and exits 0 or 1 accordingly.

set -eu

INDEX="plan/index.yaml"
SCHEMA="plan/schema.yaml"

if [ ! -f "$INDEX" ] || [ ! -f "$SCHEMA" ]; then
  echo "blocked:status-vocab-diverges: could not read $INDEX or $SCHEMA"
  exit 1
fi

# Rewritten from python3 (tlatoani_hard_no_python). Ruby is the methodology's
# sanctioned YAML fallback and this script runs HOST-side, where ruby exists.
ruby -ryaml -e '
  idx = YAML.load_file(ARGV[0])
  sch = YAML.load_file(ARGV[1])
  idx_list = (idx["plan_index"] || {})["default_status_values"] || []
  sch_list = sch["statuses"] || []
  if idx_list != sch_list
    puts "blocked:status-vocab-diverges: plan/index.yaml=(#{idx_list.join(" ")}) vs plan/schema.yaml=(#{sch_list.join(" ")})"
    exit 1
  end
  puts "ok:status-vocab-in-sync"
' "$INDEX" "$SCHEMA"
